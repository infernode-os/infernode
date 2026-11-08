// trtsrv's shim: TensorRT's C++ API as a few C functions (#1086).
//
// TensorRT's only native interface is C++ classes, so this file is the
// only C++ in trtsrv. It loads an engine (the DLA core chosen before it is
// deserialized: set after, TensorRT runs it on the GPU without saying so),
// says what its tensors and layers are, and runs one inference on a
// context of its own. It decides nothing: which engine, where, and whether
// its layers are where they should be are trtsrv's (src/trt.rs).
//
// Every function returns 0 or -1, and on -1 writes why into err (always
// NUL-terminated, at most errlen bytes).

#include <NvInfer.h>
#include <cuda_runtime_api.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Logger : nvinfer1::ILogger {
	void log(Severity sev, char const* msg) noexcept override
	{
		if(sev <= Severity::kERROR)
			std::fprintf(stderr, "trtsrv: tensorrt: %s\n", msg);
	}
};

Logger logger;

void seterr(char* err, int errlen, std::string const& s)
{
	if(err == nullptr || errlen <= 0)
		return;
	std::snprintf(err, (size_t)errlen, "%s", s.c_str());
}

std::string cudaerr(char const* what, cudaError_t e)
{
	return std::string(what) + ": " + cudaGetErrorString(e);
}

}

struct TrtEngine {
	nvinfer1::IRuntime* rt = nullptr;
	nvinfer1::ICudaEngine* eng = nullptr;
	std::vector<std::string> names;		// I/O tensors, in the engine's order
	std::vector<int> isinput;
	std::vector<int> esize;			// 4 float32, 2 float16
	std::vector<size_t> bytes;
};

struct TrtCtx {
	TrtEngine* e = nullptr;
	nvinfer1::IExecutionContext* ctx = nullptr;
	cudaStream_t stream = nullptr;
	std::vector<void*> dev;
	void* hin = nullptr;			// pinned host buffers, made once:
	void* hout = nullptr;			// the copies to and from the device are DMA
	size_t nin = 0, nout = 0;
};

extern "C" {

void trt_ctxfree(TrtCtx* c);

// the engine in blob (len bytes), on DLA core dla (-1: the GPU)
int trt_load(void const* blob, size_t len, int dla, TrtEngine** out, char* err, int errlen)
{
	*out = nullptr;
	auto* e = new TrtEngine;
	e->rt = nvinfer1::createInferRuntime(logger);
	if(e->rt == nullptr){
		delete e;
		seterr(err, errlen, "cannot make a runtime");
		return -1;
	}
	if(dla >= 0){
		if(dla >= e->rt->getNbDLACores()){
			delete e->rt;
			delete e;
			seterr(err, errlen, "no DLA core " + std::to_string(dla));
			return -1;
		}
		e->rt->setDLACore(dla);
	}
	e->eng = e->rt->deserializeCudaEngine(blob, len);
	if(e->eng == nullptr){
		delete e->rt;
		delete e;
		seterr(err, errlen, "the engine does not deserialize here");
		return -1;
	}
	int n = e->eng->getNbIOTensors();
	for(int i = 0; i < n; i++){
		char const* name = e->eng->getIOTensorName(i);
		nvinfer1::DataType dt = e->eng->getTensorDataType(name);
		int es = dt == nvinfer1::DataType::kFLOAT ? 4 : dt == nvinfer1::DataType::kHALF ? 2 : 0;
		if(es == 0){
			delete e->eng;
			delete e->rt;
			delete e;
			seterr(err, errlen, std::string("tensor ") + name + " is neither float32 nor float16");
			return -1;
		}
		nvinfer1::Dims d = e->eng->getTensorShape(name);
		size_t b = es;
		for(int k = 0; k < d.nbDims; k++){
			if(d.d[k] <= 0){
				delete e->eng;
				delete e->rt;
				delete e;
				seterr(err, errlen, std::string("tensor ") + name + " has no fixed shape");
				return -1;
			}
			b *= (size_t)d.d[k];
		}
		e->names.push_back(name);
		e->isinput.push_back(e->eng->getTensorIOMode(name) == nvinfer1::TensorIOMode::kINPUT);
		e->esize.push_back(es);
		e->bytes.push_back(b);
	}
	*out = e;
	return 0;
}

void trt_free(TrtEngine* e)
{
	if(e == nullptr)
		return;
	delete e->eng;
	delete e->rt;
	delete e;
}

int trt_ntensors(TrtEngine* e)
{
	return (int)e->names.size();
}

// tensor i: its name (NUL-terminated into name), whether an input, the
// bytes of an element (4, 2), its dimensions (into dims, at most 8), how many
int trt_tensor(TrtEngine* e, int i, char* name, int namelen, int* isinput, int* esize, int* dims, int* ndims)
{
	if(i < 0 || i >= (int)e->names.size())
		return -1;
	std::snprintf(name, (size_t)namelen, "%s", e->names[i].c_str());
	*isinput = e->isinput[i];
	*esize = e->esize[i];
	nvinfer1::Dims d = e->eng->getTensorShape(e->names[i].c_str());
	int n = d.nbDims < 8 ? d.nbDims : 8;
	for(int k = 0; k < n; k++)
		dims[k] = (int)d.d[k];
	*ndims = n;
	return 0;
}

// the engine's layers, a JSON object each as its inspector gives it, a line each
int trt_layers(TrtEngine* e, char* buf, int buflen)
{
	nvinfer1::IEngineInspector* in = e->eng->createEngineInspector();
	if(in == nullptr)
		return -1;
	std::string s;
	int n = e->eng->getNbLayers();
	for(int i = 0; i < n; i++){
		char const* l = in->getLayerInformation(i, nvinfer1::LayerInformationFormat::kJSON);
		std::string j = l != nullptr ? l : "?";
		for(char& ch : j)
			if(ch == '\n')
				ch = ' ';	// a layer a line
		s += j;
		s += "\n";
	}
	delete in;
	std::snprintf(buf, (size_t)buflen, "%s", s.c_str());
	return (int)s.size() < buflen ? 0 : -1;
}

// a context of its own, with its stream and device memory, made once
int trt_ctx(TrtEngine* e, TrtCtx** out, char* err, int errlen)
{
	*out = nullptr;
	auto* c = new TrtCtx;
	c->e = e;
	c->ctx = e->eng->createExecutionContext();
	if(c->ctx == nullptr){
		delete c;
		seterr(err, errlen, "cannot make an execution context");
		return -1;
	}
	cudaError_t ce = cudaStreamCreate(&c->stream);
	if(ce != cudaSuccess){
		delete c->ctx;
		delete c;
		seterr(err, errlen, cudaerr("stream", ce));
		return -1;
	}
	for(size_t i = 0; i < e->names.size(); i++){
		void* p = nullptr;
		ce = cudaMalloc(&p, e->bytes[i]);
		if(ce != cudaSuccess){
			for(void* q : c->dev)
				cudaFree(q);
			cudaStreamDestroy(c->stream);
			delete c->ctx;
			delete c;
			seterr(err, errlen, cudaerr("device memory", ce));
			return -1;
		}
		c->dev.push_back(p);
		c->ctx->setTensorAddress(e->names[i].c_str(), p);
		(e->isinput[i] ? c->nin : c->nout) += e->bytes[i];
	}
	if((ce = cudaMallocHost(&c->hin, c->nin)) != cudaSuccess || (ce = cudaMallocHost(&c->hout, c->nout)) != cudaSuccess){
		trt_ctxfree(c);
		seterr(err, errlen, cudaerr("pinned memory", ce));
		return -1;
	}
	*out = c;
	return 0;
}

void trt_ctxfree(TrtCtx* c)
{
	if(c == nullptr)
		return;
	if(c->hin != nullptr)
		cudaFreeHost(c->hin);
	if(c->hout != nullptr)
		cudaFreeHost(c->hout);
	for(void* q : c->dev)
		cudaFree(q);
	if(c->stream != nullptr)
		cudaStreamDestroy(c->stream);
	delete c->ctx;
	delete c;
}

// one inference: in is the inputs' bytes, in the engine's order, inlen
// exactly theirs; out gets the outputs', in order, outlen exactly theirs
int trt_run(TrtCtx* c, void const* in, size_t inlen, void* out, size_t outlen, char* err, int errlen)
{
	TrtEngine* e = c->e;
	size_t want_in = 0, want_out = 0;
	for(size_t i = 0; i < e->names.size(); i++)
		(e->isinput[i] ? want_in : want_out) += e->bytes[i];
	if(inlen != want_in || outlen != want_out){
		seterr(err, errlen, "sizes are not the engine's");
		return -1;
	}
	std::memcpy(c->hin, in, inlen);
	size_t ino = 0;
	for(size_t i = 0; i < e->names.size(); i++)
		if(e->isinput[i]){
			cudaError_t ce = cudaMemcpyAsync(c->dev[i], (char const*)c->hin + ino, e->bytes[i], cudaMemcpyHostToDevice, c->stream);
			if(ce != cudaSuccess){
				seterr(err, errlen, cudaerr("copy in", ce));
				return -1;
			}
			ino += e->bytes[i];
		}
	if(!c->ctx->enqueueV3(c->stream)){
		seterr(err, errlen, "the engine did not run");
		return -1;
	}
	size_t outo = 0;
	for(size_t i = 0; i < e->names.size(); i++)
		if(!e->isinput[i]){
			cudaError_t ce = cudaMemcpyAsync((char*)c->hout + outo, c->dev[i], e->bytes[i], cudaMemcpyDeviceToHost, c->stream);
			if(ce != cudaSuccess){
				seterr(err, errlen, cudaerr("copy out", ce));
				return -1;
			}
			outo += e->bytes[i];
		}
	cudaError_t ce = cudaStreamSynchronize(c->stream);
	if(ce != cudaSuccess){
		seterr(err, errlen, cudaerr("run", ce));
		return -1;
	}
	std::memcpy(out, c->hout, outlen);
	return 0;
}

}
