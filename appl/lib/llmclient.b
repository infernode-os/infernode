implement Llmclient;

#
# llmclient - LLM API client library
#
# HTTP-based access to LLM APIs with streaming SSE support.
# Supports Anthropic Messages API and OpenAI-compatible Chat Completions API.
#
# No external dependencies beyond Inferno stdlib + json module.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "tls.m";
	tlsmod: TLS;
	Conn: import tlsmod;

include "json.m";
	json: JSON;
	JValue: import json;

include "llmclient.m";

stderr: ref Sys->FD;
debugseq := 0;

init()
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil)
		raise "fail:llmclient: cannot load String";

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		raise "fail:llmclient: cannot load Bufio";

	json = load JSON JSON->PATH;
	if(json == nil)
		raise "fail:llmclient: cannot load JSON";
	json->init(bufio);
}

# ==================== Anthropic Messages API ====================

askanthropic(apikey, apiurl: string, req: ref AskRequest): (ref AskResponse, string)
{
	if(apiurl == nil || apiurl == "")
		apiurl = "api.anthropic.com";

	body := buildanthropicrequest(req);

	# Debug: dump request body when /tmp/llm-debug exists
	dpath := sys->sprint("/tmp/llm-req-%d.json", debugseq++);
	debugfd := sys->create(dpath, Sys->OWRITE, 8r666);
	if(debugfd != nil) {
		d := array of byte body;
		sys->write(debugfd, d, len d);
		debugfd = nil;
	}

	headers := "Content-Type: application/json\r\n" +
		"x-api-key: " + apikey + "\r\n" +
		"anthropic-version: 2023-06-01\r\n";

	if(req.streamch != nil)
		headers += "Accept: text/event-stream\r\n";

	(respbody, err) := httpspost(apiurl, "443", "/v1/messages", headers, body);
	if(err != nil)
		return (nil, "anthropic: " + err);

	if(req.streamch != nil)
		return parseanthropicsse(respbody, req);

	return parseanthropicresponse(respbody, req);
}

buildanthropicrequest(req: ref AskRequest): string
{
	s := "{";
	s += "\"model\":" + jquote(req.model) + ",";
	mt := req.maxtokens;
	if(mt <= 0)
		mt = 8192;
	s += sys->sprint("\"max_tokens\":%d,", mt);
	s += sys->sprint("\"temperature\":%.2f", req.temperature);

	# System prompt — cache_control marks it for Anthropic prompt caching.
	# The cache hierarchy is tools → system → messages; caching the system
	# block (along with tools below) means the entire static prefix is
	# served from cache on turns 2+ at 0.1× input token cost.
	if(req.systemprompt != "")
		s += ",\"system\":[{\"type\":\"text\",\"text\":" + jquote(req.systemprompt) +
			",\"cache_control\":{\"type\":\"ephemeral\"}}]";

	# Stream flag
	if(req.streamch != nil)
		s += ",\"stream\":true";

	# Messages
	s += ",\"messages\":[";
	first := 1;
	mi := 0;
	for(ml := req.messages; ml != nil; ml = tl ml) {
		m := hd ml;
		if(m.role == "system")
			continue;
		if(!first)
			s += ",";
		first = 0;
		msg := buildanthropicmessage(m);
		sys->fprint(stderr, "llmclient: msg[%d] role=%s sc=%d content=%d\n",
			mi, m.role, len m.sc, len m.content);
		s += msg;
		mi++;
	}

	# Add new prompt or tool results
	if(req.toolresults != nil) {
		if(!first)
			s += ",";
		s += buildtoolresultsmessage(req.toolresults);
		sys->fprint(stderr, "llmclient: msg[%d] appended tool_results\n", mi);
	} else if(req.prompt != "") {
		if(!first)
			s += ",";
		s += "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":" + jquote(req.prompt) + "}]}";
		sys->fprint(stderr, "llmclient: msg[%d] appended prompt (%d bytes)\n", mi, len req.prompt);
	}

	# Add prefill (only when no tools)
	if(req.prefill != "" && req.tooldefs == nil) {
		s += ",{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":" + jquote(req.prefill) + "}]}";
	}

	s += "]";

	# Tool definitions — mark the last tool with cache_control so the
	# entire tools array is included in the cached prefix.
	if(req.tooldefs != nil) {
		s += ",\"tools\":[";
		tfirst := 1;
		for(tl2 := req.tooldefs; tl2 != nil; tl2 = tl tl2) {
			td := hd tl2;
			if(!tfirst)
				s += ",";
			tfirst = 0;
			s += "{\"name\":" + jquote(td.name) +
				",\"description\":" + jquote(td.description) +
				",\"input_schema\":" + td.inputschema;
			if(tl tl2 == nil)
				s += ",\"cache_control\":{\"type\":\"ephemeral\"}";
			s += "}";
		}
		s += "],\"tool_choice\":{\"type\":\"auto\"}";
	}

	s += "}";
	return s;
}

buildanthropicmessage(m: ref LlmMessage): string
{
	role := m.role;

	# If structured content exists, use it directly
	if(m.sc != "") {
		return "{\"role\":" + jquote(role) + ",\"content\":" + m.sc + "}";
	}

	# Plain text message — guard against empty text blocks
	content := m.content;
	if(content == "")
		content = "...";

	return "{\"role\":" + jquote(role) + ",\"content\":[{\"type\":\"text\",\"text\":" + jquote(content) + "}]}";
}

buildtoolresultsmessage(results: list of ref ToolResult): string
{
	s := "{\"role\":\"user\",\"content\":[";
	first := 1;
	for(; results != nil; results = tl results) {
		r := hd results;
		if(!first)
			s += ",";
		first = 0;
		s += "{\"type\":\"tool_result\",\"tool_use_id\":" + jquote(r.tooluseid) +
			",\"content\":" + jquote(r.content) + "}";
	}
	s += "]}";
	return s;
}

parseanthropicresponse(body: string, req: ref AskRequest): (ref AskResponse, string)
{
	(jv, jerr) := readjsonstring(body);
	if(jerr != nil)
		return (nil, "anthropic: parse error: " + jerr);

	# Check for error response
	errv := jv.get("error");
	if(errv != nil) {
		emsg := jv.get("error").get("message");
		if(emsg != nil) {
			pick em := emsg {
			String => return (nil, em.s);
			}
		}
		return (nil, "anthropic: API error");
	}

	# Extract tokens
	tokens := 0;
	usage := jv.get("usage");
	if(usage != nil) {
		itok := usage.get("input_tokens");
		otok := usage.get("output_tokens");
		if(itok != nil) pick iv := itok { Int => tokens += int iv.value; }
		if(otok != nil) pick ov := otok { Int => tokens += int ov.value; }
	}

	# Extract content blocks
	content := jv.get("content");
	if(content == nil)
		return (nil, "anthropic: no content in response");

	textparts: list of string;
	toollines: list of string;
	structblocks: list of string;
	stopreason := "";

	srv := jv.get("stop_reason");
	if(srv != nil) pick sr := srv { String => stopreason = sr.s; }

	pick ca := content {
	Array =>
		for(i := 0; i < len ca.a; i++) {
			block := ca.a[i];
			typev := block.get("type");
			if(typev == nil)
				continue;
			typestr := "";
			pick tv := typev { String => typestr = tv.s; }

			case typestr {
			"text" =>
				textv := block.get("text");
				if(textv != nil) {
					pick tv := textv {
					String =>
						if(tv.s != "") {
							textparts = tv.s :: textparts;
							structblocks = ("{\"type\":\"text\",\"text\":" + jquote(tv.s) + "}") :: structblocks;
						}
					}
				}
			"tool_use" =>
				idv := block.get("id");
				namev := block.get("name");
				inputv := block.get("input");
				id := "";
				name := "";
				inputjson := "{}";
				if(idv != nil) pick iv := idv { String => id = iv.s; }
				if(namev != nil) pick nv := namev { String => name = nv.s; }
				if(inputv != nil)
					inputjson = inputv.text();
				args := extracttoolargs(inputjson);
				safeargs := replaceall(args, "\n", "\\n");
				toollines = sys->sprint("TOOL:%s:%s:%s", id, name, safeargs) :: toollines;
				structblocks = ("{\"type\":\"tool_use\",\"id\":" + jquote(id) +
					",\"name\":" + jquote(name) +
					",\"input\":" + inputjson + "}") :: structblocks;
			}
		}
	}

	# No tools defined — plain text mode
	if(req.tooldefs == nil) {
		text := joinrev(textparts, "");
		if(req.prefill != "" && !hasprefix(text, req.prefill))
			text = req.prefill + text;
		return (ref AskResponse(text, "", tokens), nil);
	}

	# Tool mode — build STOP: response
	structjson := "";
	if(structblocks != nil)
		structjson = "[" + joinrev(structblocks, ",") + "]";

	response := "";
	if(stopreason == "tool_use")
		response = "STOP:tool_use\n";
	else
		response = "STOP:end_turn\n";
	response += joinrev(toollines, "\n");
	if(toollines != nil)
		response += "\n";
	response += joinrev(textparts, "");

	return (ref AskResponse(response, structjson, tokens), nil);
}

parseanthropicsse(body: string, req: ref AskRequest): (ref AskResponse, string)
{
	# The body was received in full from httpspost.
	# Parse SSE events from it line by line.
	# For true streaming over TLS, we'd need to read incrementally,
	# but httpspost reads to completion. The streaming chunks are still
	# sent to req.streamch for the Styx stream file.

	fulltext := "";
	toollines: list of string;
	structblocks: list of string;
	tokens := 0;
	stopreason := "";

	# Per-tool accumulation for streaming tool_use
	# Track current tool block's id, name, and partial input JSON
	curtoolid := "";
	curtoolname := "";
	curtoolinput := "";

	lines := splitlines(body);
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(line == "" || line == "\r")
			continue;
		if(!hasprefix(line, "data: "))
			continue;
		data := line[6:];
		if(data == "[DONE]")
			break;

		(jv, jerr) := readjsonstring(data);
		if(jerr != nil)
			continue;

		typev := jv.get("type");
		if(typev == nil)
			continue;
		typestr := "";
		pick tv := typev { String => typestr = tv.s; }

		case typestr {
		"content_block_delta" =>
			delta := jv.get("delta");
			if(delta == nil)
				continue;
			dtv := delta.get("type");
			if(dtv == nil)
				continue;
			dtypestr := "";
			pick dtval := dtv { String => dtypestr = dtval.s; }
			if(dtypestr == "text_delta") {
				textv := delta.get("text");
				if(textv != nil) {
					pick tv := textv {
					String =>
						fulltext += tv.s;
						if(req.streamch != nil) {
							alt {
								req.streamch <-= tv.s => ;
								* => ;  # drop if full
							}
						}
					}
				}
			} else if(dtypestr == "input_json_delta") {
				pjv := delta.get("partial_json");
				if(pjv != nil)
					pick pv := pjv { String => curtoolinput += pv.s; }
			}
		"message_delta" =>
			usagev := jv.get("usage");
			if(usagev != nil) {
				otv := usagev.get("output_tokens");
				if(otv != nil) pick ov := otv { Int => tokens += int ov.value; }
			}
			srv := jv.get("delta");
			if(srv != nil) {
				srr := srv.get("stop_reason");
				if(srr != nil) pick sr := srr { String => stopreason = sr.s; }
			}
		"message_start" =>
			msgv := jv.get("message");
			if(msgv != nil) {
				usagev := msgv.get("usage");
				if(usagev != nil) {
					itv := usagev.get("input_tokens");
					if(itv != nil) pick iv := itv { Int => tokens += int iv.value; }
				}
			}
		"content_block_start" =>
			cb := jv.get("content_block");
			if(cb != nil) {
				cbtv := cb.get("type");
				if(cbtv != nil) {
					cbtypestr := "";
					pick ct := cbtv { String => cbtypestr = ct.s; }
					if(cbtypestr == "tool_use") {
						idv := cb.get("id");
						namev := cb.get("name");
						if(idv != nil) pick iv := idv { String => curtoolid = iv.s; }
						if(namev != nil) pick nv := namev { String => curtoolname = nv.s; }
						curtoolinput = "";
					}
				}
			}
		"content_block_stop" =>
			# Finalize accumulated tool input
			if(curtoolid != "") {
				inputjson := curtoolinput;
				if(inputjson == "")
					inputjson = "{}";
				args := extracttoolargs(inputjson);
				safeargs := replaceall(args, "\n", "\\n");
				toollines = sys->sprint("TOOL:%s:%s:%s", curtoolid, curtoolname, safeargs) :: toollines;
				structblocks = ("{\"type\":\"tool_use\",\"id\":" + jquote(curtoolid) +
					",\"name\":" + jquote(curtoolname) +
					",\"input\":" + inputjson + "}") :: structblocks;
				curtoolid = "";
				curtoolname = "";
				curtoolinput = "";
			}
		}
	}

	# Build response
	if(req.tooldefs == nil) {
		if(req.prefill != "" && !hasprefix(fulltext, req.prefill))
			fulltext = req.prefill + fulltext;
		return (ref AskResponse(fulltext, "", tokens), nil);
	}

	# Build structjson with text BEFORE tool_use (API requires this order)
	structjson := "";
	textblock := "";
	if(fulltext != "")
		textblock = "{\"type\":\"text\",\"text\":" + jquote(fulltext) + "}";
	if(textblock != "" || structblocks != nil) {
		structjson = "[";
		if(textblock != "")
			structjson += textblock;
		if(structblocks != nil) {
			if(textblock != "")
				structjson += ",";
			structjson += joinrev(structblocks, ",");
		}
		structjson += "]";
	}

	response := "";
	if(stopreason == "tool_use")
		response = "STOP:tool_use\n";
	else
		response = "STOP:end_turn\n";
	response += joinrev(toollines, "\n");
	if(toollines != nil)
		response += "\n";
	response += fulltext;

	return (ref AskResponse(response, structjson, tokens), nil);
}

# ==================== OpenAI-Compatible API ====================

# Streaming OpenAI dispatch — used when req.streamch != nil. Reads
# the HTTP response incrementally and forwards `delta.content` chunks
# to req.streamch as they arrive on the wire, instead of buffering
# the full body and replaying chunks in a burst.
#
# Failure-mode change vs. the buffered path: when the read stalls
# mid-response, the caller still gets back whatever content arrived
# before the stall (in fulltext) plus a non-nil error string. The
# old code would return (nil, err) and the user would see nothing.
askopenaistream(baseurl, apikey: string, req: ref AskRequest): (ref AskResponse, string)
{
	if(baseurl == nil || baseurl == "")
		baseurl = "http://localhost:11434/v1";

	body := buildopenairequestjson(req);

	(scheme, host, port, path, uerr) := parseurl(baseurl + "/chat/completions");
	if(uerr != nil)
		return (nil, "openai: " + uerr);

	headers := "Content-Type: application/json\r\n";
	if(apikey != nil && apikey != "" && apikey != "not-needed")
		headers += "Authorization: Bearer " + apikey + "\r\n";

	contentlen := len array of byte body;
	reqdata := "POST " + path + " HTTP/1.0\r\n" +
		"Host: " + host + "\r\n" +
		"Content-Length: " + string contentlen + "\r\n" +
		headers +
		"Connection: close\r\n" +
		"\r\n" + body;

	if(scheme == "https") {
		if(tlsmod == nil) {
			tlsmod = load TLS TLS->PATH;
			if(tlsmod == nil)
				return (nil, "openai: cannot load TLS module");
			terr := tlsmod->init();
			if(terr != nil)
				return (nil, "openai: TLS init: " + terr);
		}
		(ok, conn) := sys->dial("tcp!" + host + "!" + port, nil);
		if(ok < 0)
			return (nil, sys->sprint("openai: cannot connect to %s: %r", host));
		config := tlsmod->defaultconfig();
		config.servername = host;
		(tc, cerr) := tlsmod->client(conn.dfd, config);
		if(cerr != nil)
			return (nil, "openai: TLS: " + cerr);
		d := array of byte reqdata;
		if(tc.write(d, len d) < 0) {
			tc.close();
			return (nil, "openai: TLS write failed");
		}
		rch := chan[1] of (int, array of byte);
		spawn _httpsread(tc, rch);
		(resp, rerr) := _sseconsume(conn, rch, req);
		tc.close();
		if(rerr != nil)
			return (resp, "openai: " + rerr);
		return (resp, nil);
	}

	# Plain HTTP path (typical: Ollama at localhost:11434).
	(ok, conn) := sys->dial("tcp!" + host + "!" + port, nil);
	if(ok < 0)
		return (nil, sys->sprint("openai: cannot connect to %s: %r", host));
	d := array of byte reqdata;
	if(sys->write(conn.dfd, d, len d) < 0)
		return (nil, sys->sprint("openai: write failed: %r"));
	rch := chan[1] of (int, array of byte);
	spawn _httpread(conn.dfd, rch);
	(resp, rerr) := _sseconsume(conn, rch, req);
	if(rerr != nil)
		return (resp, "openai: " + rerr);
	return (resp, nil);
}

# Incremental SSE consumer. Drives a byte channel (filled by
# _httpread / _httpsread) through:
#   1. HTTP header drain (until \r\n\r\n)
#   2. Status line check
#   3. SSE event drain via _ssedrain_lines, which calls
#      _ssehandle_event for each complete `data: ...` line and
#      forwards content deltas to req.streamch in real time
#
# Per-read no-progress watchdog: same shape as _httpreadloop —
# HTTP_NO_PROGRESS_MS without any bytes triggers a hangup, but a
# successful read at any time resets the timer.
#
# On timeout, returns the partial response (fulltext + tool calls
# accumulated so far) plus an error string. Caller decides what to
# do with the partial.
_sseconsume(conn: Sys->Connection, rch: chan of (int, array of byte),
            req: ref AskRequest): (ref AskResponse, string)
{
	st := ref _SseState("", 0, "", nil, nil, nil);
	headersbuf := array[0] of byte;
	bodybuf := array[0] of byte;
	in_body := 0;
	status := "";
	idle_ms := 0;
	done := 0;
	while(!done) {
		alt {
		rr := <-rch =>
			(n, rdata) := rr;
			if(n <= 0) {
				done = 1;
				break;
			}
			idle_ms = 0;
			if(!in_body) {
				# Accumulate header bytes; look for \r\n\r\n
				old := headersbuf;
				headersbuf = array[len old + n] of byte;
				headersbuf[0:] = old;
				headersbuf[len old:] = rdata[0:n];
				boundary := -1;
				for(i := 0; i + 3 < len headersbuf; i++) {
					if(headersbuf[i] == byte '\r' && headersbuf[i+1] == byte '\n' &&
					   headersbuf[i+2] == byte '\r' && headersbuf[i+3] == byte '\n') {
						boundary = i;
						break;
					}
				}
				if(boundary >= 0) {
					# Pull status line out of the header block
					hdrs := string headersbuf[0:boundary];
					nl := 0;
					for(; nl < len hdrs; nl++)
						if(hdrs[nl] == '\n')
							break;
					if(nl > 0)
						status = hdrs[0:nl];
					# Validate status
					if(status != "" && !hasprefix(status, "HTTP/1.1 200") &&
					   !hasprefix(status, "HTTP/1.0 200"))
						return (nil, "HTTP error: " + strip(status));
					in_body = 1;
					after := boundary + 4;
					if(after < len headersbuf)
						bodybuf = headersbuf[after:];
					headersbuf = array[0] of byte;
				}
			} else {
				# Append new bytes to bodybuf
				old := bodybuf;
				bodybuf = array[len old + n] of byte;
				bodybuf[0:] = old;
				bodybuf[len old:] = rdata[0:n];
			}
			if(in_body) {
				(remaining, ssedone) := _ssedrain_lines(bodybuf, st, req);
				bodybuf = remaining;
				if(ssedone)
					done = 1;
			}
		* =>
			sys->sleep(HTTP_POLL_MS);
			idle_ms += HTTP_POLL_MS;
			if(idle_ms >= HTTP_NO_PROGRESS_MS) {
				if(conn.cfd != nil)
					sys->fprint(conn.cfd, "hangup");
				# Build partial response from whatever arrived
				(presp, _) := _ssebuild_response(st, req);
				return (presp, sys->sprint(
					"HTTP read no-progress timeout after %d ms (got %d bytes of content, %d tool deltas)",
					HTTP_NO_PROGRESS_MS, len st.fulltext, listlen(st.tcids)));
			}
		}
	}
	return _ssebuild_response(st, req);
}

askopenai(baseurl, apikey: string, req: ref AskRequest): (ref AskResponse, string)
{
	# Streaming path — true incremental SSE consumption.
	# Forwards delta.content to req.streamch as it arrives on the
	# wire, not after buffering. On mid-response stall, returns
	# whatever content arrived plus an error so the caller can
	# distinguish "no data" from "stalled at chunk N."
	if(req.streamch != nil)
		return askopenaistream(baseurl, apikey, req);

	if(baseurl == nil || baseurl == "")
		baseurl = "http://localhost:11434/v1";

	body := buildopenairequestjson(req);

	(scheme, host, port, path, uerr) := parseurl(baseurl + "/chat/completions");
	if(uerr != nil)
		return (nil, "openai: " + uerr);

	headers := "Content-Type: application/json\r\n";
	if(apikey != nil && apikey != "" && apikey != "not-needed")
		headers += "Authorization: Bearer " + apikey + "\r\n";

	respbody: string;
	err: string;

	if(scheme == "https")
		(respbody, err) = httpspost(host, port, path, headers, body);
	else
		(respbody, err) = httppost(host, port, path, headers, body);

	if(err != nil)
		return (nil, "openai: " + err);

	return parseopenairesponse(respbody, req);
}

buildopenairequestjson(req: ref AskRequest): string
{
	s := "{";
	s += "\"model\":" + jquote(req.model) + ",";
	mt := req.maxtokens;
	if(mt <= 0)
		mt = 1024;
	s += sys->sprint("\"max_tokens\":%d,", mt);
	s += sys->sprint("\"temperature\":%.2f", req.temperature);

	# Stream
	if(req.streamch != nil)
		s += ",\"stream\":true,\"stream_options\":{\"include_usage\":true}";

	# Two thinking-related fields, BOTH gated on model capability (INFR-132):
	#
	#   1. reasoning_effort (OpenAI-standard top-level field). Set by
	#      serve-profile via `llmsrv -r low` to optimise gpt-oss latency.
	#      Ollama's mistral REJECTS this field with "does not support
	#      thinking" even though it's OpenAI-standard — the field itself
	#      is a thinking-enable signal regardless of who standardised it.
	#
	#   2. options.think / options.think_level (Ollama-specific sub-object).
	#      Same constraint: gpt-oss requires it set, mistral can't have it.
	#
	# thinkmode() returns "" for models that don't support thinking at
	# all; in that case we omit BOTH fields. For models that do, we emit
	# both reasoning_effort (top-level) and options.think (Ollama).
	thinkopts := thinkmode(req.model, req.thinkingtokens);
	if(thinkopts != "") {
		if(req.reasoningeffort != "")
			s += sys->sprint(",\"reasoning_effort\":%s",
				jquote(req.reasoningeffort));
		s += ",\"options\":" + thinkopts;
	}

	# Messages
	s += ",\"messages\":[";
	first := 1;

	# System prompt
	if(req.systemprompt != "") {
		s += "{\"role\":\"system\",\"content\":" + jquote(req.systemprompt) + "}";
		first = 0;
	}

	# History (system messages merged into system prompt above)
	for(ml := req.messages; ml != nil; ml = tl ml) {
		m := hd ml;
		if(m.role == "system") {
			if(!first) s += ",";
			first = 0;
			s += "{\"role\":\"system\",\"content\":" + jquote(m.content) + "}";
			continue;
		}
		if(m.sc != "" && m.role == "assistant") {
			if(!first) s += ",";
			first = 0;
			s += buildopenaitoolmessage(m);
		} else if(m.sc != "" && m.role == "user") {
			s += buildopenaitoolresultmessages(m, first);
			first = 0;
		} else {
			if(!first) s += ",";
			first = 0;
			s += "{\"role\":" + jquote(m.role) + ",\"content\":" + jquote(m.content) + "}";
		}
	}

	# New prompt or tool results
	if(req.toolresults != nil) {
		for(trl := req.toolresults; trl != nil; trl = tl trl) {
			r := hd trl;
			if(!first) s += ",";
			first = 0;
			s += "{\"role\":\"tool\",\"content\":" + jquote(r.content) +
				",\"tool_call_id\":" + jquote(r.tooluseid) + "}";
		}
	} else if(req.prompt != "") {
		if(!first) s += ",";
		first = 0;
		s += "{\"role\":\"user\",\"content\":" + jquote(req.prompt) + "}";
	}

	s += "]";

	# Tool definitions
	if(req.tooldefs != nil) {
		s += ",\"tools\":[";
		tfirst := 1;
		for(tdl := req.tooldefs; tdl != nil; tdl = tl tdl) {
			td := hd tdl;
			if(!tfirst) s += ",";
			tfirst = 0;
			s += "{\"type\":\"function\",\"function\":{" +
				"\"name\":" + jquote(td.name) + "," +
				"\"description\":" + jquote(td.description) + "," +
				"\"parameters\":" + td.inputschema + "}}";
		}
		s += "],\"tool_choice\":\"auto\"";
	}

	s += "}";
	return s;
}

buildopenaitoolmessage(m: ref LlmMessage): string
{
	# Reconstruct assistant message with tool_calls from structured content
	(jv, jerr) := readjsonstring(m.sc);
	if(jerr != nil)
		return "{\"role\":\"assistant\",\"content\":" + jquote(m.content) + "}";

	content := "";
	toolcalls := "";
	tcfirst := 1;
	idx := 0;

	pick a := jv {
	Array =>
		for(i := 0; i < len a.a; i++) {
			block := a.a[i];
			typev := block.get("type");
			if(typev == nil) continue;
			typestr := "";
			pick tv := typev { String => typestr = tv.s; }

			case typestr {
			"text" =>
				textv := block.get("text");
				if(textv != nil) pick tv := textv { String => content += tv.s; }
			"tool_use" =>
				idv := block.get("id");
				namev := block.get("name");
				inputv := block.get("input");
				id := "";
				name := "";
				inputjson := "{}";
				if(idv != nil) pick iv := idv { String => id = iv.s; }
				if(namev != nil) pick nv := namev { String => name = nv.s; }
				if(inputv != nil) inputjson = inputv.text();

				if(!tcfirst) toolcalls += ",";
				tcfirst = 0;
				toolcalls += sys->sprint("{\"index\":%d,\"id\":%s,\"type\":\"function\",\"function\":{\"name\":%s,\"arguments\":%s}}",
					idx, jquote(id), jquote(name), jquote(inputjson));
				idx++;
			}
		}
	}

	s := "{\"role\":\"assistant\"";
	if(content != "")
		s += ",\"content\":" + jquote(content);
	else
		s += ",\"content\":\"\"";
	if(toolcalls != "")
		s += ",\"tool_calls\":[" + toolcalls + "]";
	s += "}";
	return s;
}

# Convert a user-role message with Anthropic tool_result structured content
# into OpenAI-format {"role":"tool"} messages.  Each tool_result block becomes
# a separate message with tool_call_id and content.
buildopenaitoolresultmessages(m: ref LlmMessage, first: int): string
{
	(jv, jerr) := readjsonstring(m.sc);
	if(jerr != nil) {
		# Fallback: emit as plain user message
		s := "";
		if(!first) s += ",";
		s += "{\"role\":\"user\",\"content\":" + jquote(m.content) + "}";
		return s;
	}

	s := "";
	pick a := jv {
	Array =>
		for(i := 0; i < len a.a; i++) {
			block := a.a[i];
			typev := block.get("type");
			if(typev == nil) continue;
			typestr := "";
			pick tv := typev { String => typestr = tv.s; }
			if(typestr != "tool_result")
				continue;

			idv := block.get("tool_use_id");
			contentv := block.get("content");
			id := "";
			content := "";
			if(idv != nil) pick iv := idv { String => id = iv.s; }
			if(contentv != nil) pick cv := contentv { String => content = cv.s; }

			if(!first || s != "") s += ",";
			s += "{\"role\":\"tool\",\"content\":" + jquote(content) +
				",\"tool_call_id\":" + jquote(id) + "}";
		}
	}

	if(s == "") {
		# No tool_result blocks found; emit as plain user message
		if(!first) s += ",";
		s += "{\"role\":\"user\",\"content\":" + jquote(m.content) + "}";
	}
	return s;
}

thinkoptions(tokens: int): string
{
	# Retained for backward compatibility with any in-tree caller that
	# can't pass a model name. New code should call thinkmode(model,
	# tokens) instead — see INFR-132.
	if(tokens == 0)
		return "{\"think\":false}";
	level := "high";
	if(tokens > 0 && tokens <= 10000)
		level = "low";
	else if(tokens > 0 && tokens <= 20000)
		level = "medium";
	return "{\"think\":true,\"think_level\":\"" + level + "\"}";
}

# thinkmode emits the Ollama `options.think*` JSON object based on the
# *model's* capability, not just the requested budget. INFR-132.
#
# Operator-confirmed constraints (pdf, 2026-05):
#   - gpt-oss family REQUIRES think:true to function. Sending {think:false}
#     actively breaks it. Best default level is "low" — measured 15x faster
#     on tool-driven scenarios with no quality loss vs medium.
#   - Mistral family (via Ollama right now) does not support the
#     `reasoning_effort` / `options.think` fields. Sending either errors
#     the request with: `Error: "<model>" does not support thinking`.
#     Must be omitted entirely.
#
# Returns the JSON value for options.think (or the full options sub-object
# when needed) or "" to signal "do not emit the options key at all".
thinkmode(model: string, tokens: int): string
{
	if(hasprefix(model, "gpt-oss") || hasprefix(model, "deepseek-r1")) {
		# Thinking-required family. tokens==0 means "use the operator
		# default" — low — not "disable thinking".
		level := "low";
		if(tokens > 0 && tokens <= 10000)
			level = "low";
		else if(tokens > 0 && tokens <= 20000)
			level = "medium";
		else if(tokens > 20000)
			level = "high";
		return "{\"think\":true,\"think_level\":\"" + level + "\"}";
	}
	# Thinking-unsupported family: mistral, llama, plain qwen, etc.
	# Emitting nothing here causes the call site to drop the entire
	# options key from the request body. This is exactly what these
	# backends need.
	return "";
}

parseopenairesponse(body: string, req: ref AskRequest): (ref AskResponse, string)
{
	(jv, jerr) := readjsonstring(body);
	if(jerr != nil)
		return (nil, "openai: parse error: " + jerr);

	# Check for error
	errv := jv.get("error");
	if(errv != nil) {
		emsg := errv.get("message");
		if(emsg != nil) pick em := emsg { String => return (nil, em.s); }
		# Fall back to the error value's JSON text — gives the
		# operator something to grep for. Some backends (Ollama,
		# the Mac→Hephaestus path) return tiny non-standard error
		# bodies like {"error":"timeout"} where there is no
		# message field; "openai: API error" alone hid them.
		pick es := errv { String => return (nil, "openai: " + es.s); }
		return (nil, "openai: API error: " + errv.text());
	}

	# Extract tokens
	tokens := 0;
	usage := jv.get("usage");
	if(usage != nil) {
		tv := usage.get("total_tokens");
		if(tv != nil) pick t := tv { Int => tokens = int t.value; }
	}

	# Extract response
	choices := jv.get("choices");
	if(choices == nil)
		return (nil, "openai: no choices in response");

	responsetext := "";
	finishreason := "";
	toolcalls: list of (string, string, string);  # (id, name, args)

	pick ca := choices {
	Array =>
		if(len ca.a == 0)
			return (nil, "openai: empty choices");
		choice := ca.a[0];

		frv := choice.get("finish_reason");
		if(frv != nil) pick fr := frv { String => finishreason = fr.s; }

		msg := choice.get("message");
		if(msg != nil) {
			cv := msg.get("content");
			if(cv != nil) pick c := cv { String => responsetext = c.s; }

			tcv := msg.get("tool_calls");
			if(tcv != nil) {
				pick tca := tcv {
				Array =>
					for(i := 0; i < len tca.a; i++) {
						tc := tca.a[i];
						idv := tc.get("id");
						fnv := tc.get("function");
						id := "";
						name := "";
						args := "";
						if(idv != nil) pick iv := idv { String => id = iv.s; }
						if(fnv != nil) {
							nv := fnv.get("name");
							av := fnv.get("arguments");
							if(nv != nil) pick n := nv { String => name = n.s; }
							if(av != nil) pick a := av { String => args = a.s; }
						}
						toolcalls = (id, name, args) :: toolcalls;
					}
				}
			}
		}
	}

	if(tokens == 0)
		tokens = estimatetokens(responsetext);

	# Fallback: parse tool calls from text content if model didn't use structured API
	if(toolcalls == nil && responsetext != "" && req.tooldefs != nil) {
		(remaining, extracted) := extracttexttoolcalls(responsetext, req.tooldefs);
		if(extracted != nil) {
			toolcalls = extracted;
			responsetext = strip(remaining);
			finishreason = "tool_calls";
		}
	}

	# Plain text mode
	if(req.tooldefs == nil) {
		if(req.prefill != "" && !hasprefix(responsetext, req.prefill))
			responsetext = req.prefill + responsetext;
		return (ref AskResponse(responsetext, "", tokens), nil);
	}

	# Tool mode — build STOP: response
	textparts: list of string;
	toolentries: list of string;
	structblocks: list of string;

	if(responsetext != "") {
		textparts = responsetext :: nil;
		structblocks = ("{\"type\":\"text\",\"text\":" + jquote(responsetext) + "}") :: structblocks;
	}

	# Reverse toolcalls to restore original order
	revtc: list of (string, string, string);
	for(; toolcalls != nil; toolcalls = tl toolcalls)
		revtc = hd toolcalls :: revtc;

	for(; revtc != nil; revtc = tl revtc) {
		(id, name, rawargs) := hd revtc;
		args := extracttoolargs(rawargs);
		safeargs := replaceall(args, "\n", "\\n");
		toolentries = sys->sprint("TOOL:%s:%s:%s", id, name, safeargs) :: toolentries;
		inputjson := rawargs;
		if(inputjson == "")
			inputjson = "{}";
		structblocks = ("{\"type\":\"tool_use\",\"id\":" + jquote(id) +
			",\"name\":" + jquote(name) +
			",\"input\":" + inputjson + "}") :: structblocks;
	}

	structjson := "";
	if(structblocks != nil)
		structjson = "[" + joinrev(structblocks, ",") + "]";

	response := "";
	if(finishreason == "tool_calls")
		response = "STOP:tool_use\n";
	else
		response = "STOP:end_turn\n";
	response += joinrev(toolentries, "\n");
	if(toolentries != nil)
		response += "\n";
	response += joinrev(textparts, "");

	return (ref AskResponse(response, structjson, tokens), nil);
}

# Streaming SSE state — accumulated across multiple `data: {...}` events.
# Lives inside _ssehandle_event (called per-event) and in the new
# askopenaistream / parseopenaisseresponse drivers. ref adt so callers
# can mutate via the helper without passing 6 separate by-ref params.
_SseState: adt {
	fulltext:     string;
	tokens:       int;
	finishreason: string;
	# Tool-call delta accumulation. Parallel lists as maps
	# (index → id, name, args). Each new SSE event may extend
	# any of these.
	tcids:    list of string;
	tcnames:  list of string;
	tcargs:   list of string;
};

# Process one parsed SSE event JSON value into the running state.
# Mutates `st` in place (it's a ref adt — list reassignments survive
# because the adt itself is shared).
_ssehandle_event(jv: ref JValue, st: ref _SseState, req: ref AskRequest)
{
	# Usage
	usagev := jv.get("usage");
	if(usagev != nil) {
		tv := usagev.get("total_tokens");
		if(tv != nil) pick t := tv { Int => st.tokens = int t.value; }
	}

	# Choices
	choices := jv.get("choices");
	if(choices == nil)
		return;
	pick ca := choices {
	Array =>
		if(len ca.a == 0)
			return;
		choice := ca.a[0];

		# Finish reason
		frv := choice.get("finish_reason");
		if(frv != nil) pick fr := frv { String => if(fr.s != "") st.finishreason = fr.s; }

		delta := choice.get("delta");
		if(delta == nil)
			return;

		# Text delta — append to fulltext AND forward to streamch
		# (non-blocking; drops on full because streamch is the live
		# display feed, not the authoritative response — fulltext is).
		cv := delta.get("content");
		if(cv != nil) {
			pick c := cv {
			String =>
				if(c.s != "") {
					st.fulltext += c.s;
					if(req.streamch != nil) {
						alt {
							req.streamch <-= c.s => ;
							* => ;
						}
					}
				}
			}
		}

		# Tool-call deltas
		tcv := delta.get("tool_calls");
		if(tcv != nil) {
			pick tca := tcv {
			Array =>
				for(i := 0; i < len tca.a; i++) {
					tc := tca.a[i];
					idxv := tc.get("index");
					idx := 0;
					if(idxv != nil) pick iv := idxv { Int => idx = int iv.value; }
					while(listlen(st.tcids) <= idx) {
						st.tcids = append(st.tcids, "");
						st.tcnames = append(st.tcnames, "");
						st.tcargs = append(st.tcargs, "");
					}
					idv := tc.get("id");
					if(idv != nil) pick iv := idv { String => if(iv.s != "") st.tcids = listset(st.tcids, idx, iv.s); }
					fnv := tc.get("function");
					if(fnv != nil) {
						nv := fnv.get("name");
						if(nv != nil) pick n := nv { String => if(n.s != "") st.tcnames = listset(st.tcnames, idx, listget(st.tcnames, idx) + n.s); }
						av := fnv.get("arguments");
						if(av != nil) pick a := av { String => st.tcargs = listset(st.tcargs, idx, listget(st.tcargs, idx) + a.s); }
					}
				}
			}
		}
	}
}

# Build the final AskResponse from the accumulated SSE state.
# Shared between the streaming driver (askopenaistream) and the
# buffered fallback (parseopenaisseresponse).
_ssebuild_response(st: ref _SseState, req: ref AskRequest): (ref AskResponse, string)
{
	if(st.tokens == 0)
		st.tokens = estimatetokens(st.fulltext);

	# Text tool-call fallback for models that emit tools as plain text
	if(st.tcids == nil && st.fulltext != "" && req.tooldefs != nil) {
		(remaining, extracted) := extracttexttoolcalls(st.fulltext, req.tooldefs);
		if(extracted != nil) {
			for(el := extracted; el != nil; el = tl el) {
				(eid, ename, eargs) := hd el;
				st.tcids = append(st.tcids, eid);
				st.tcnames = append(st.tcnames, ename);
				st.tcargs = append(st.tcargs, eargs);
			}
			st.fulltext = strip(remaining);
			st.finishreason = "tool_calls";
		}
	}

	# Plain text mode
	if(req.tooldefs == nil) {
		if(req.prefill != "" && !hasprefix(st.fulltext, req.prefill))
			st.fulltext = req.prefill + st.fulltext;
		return (ref AskResponse(st.fulltext, "", st.tokens), nil);
	}

	# Tool mode
	textparts: list of string;
	toolentries: list of string;
	structblocks: list of string;

	if(st.fulltext != "") {
		textparts = st.fulltext :: nil;
		structblocks = ("{\"type\":\"text\",\"text\":" + jquote(st.fulltext) + "}") :: nil;
	}

	n := listlen(st.tcids);
	for(i := 0; i < n; i++) {
		id := listget(st.tcids, i);
		name := listget(st.tcnames, i);
		rawargs := listget(st.tcargs, i);
		args := extracttoolargs(rawargs);
		safeargs := replaceall(args, "\n", "\\n");
		toolentries = sys->sprint("TOOL:%s:%s:%s", id, name, safeargs) :: toolentries;
		inputjson := rawargs;
		if(inputjson == "")
			inputjson = "{}";
		structblocks = ("{\"type\":\"tool_use\",\"id\":" + jquote(id) +
			",\"name\":" + jquote(name) +
			",\"input\":" + inputjson + "}") :: structblocks;
	}

	structjson := "";
	if(structblocks != nil)
		structjson = "[" + joinrev(structblocks, ",") + "]";

	response := "";
	if(st.finishreason == "tool_calls")
		response = "STOP:tool_use\n";
	else
		response = "STOP:end_turn\n";
	response += joinrev(toolentries, "\n");
	if(toolentries != nil)
		response += "\n";
	response += joinrev(textparts, "");

	return (ref AskResponse(response, structjson, st.tokens), nil);
}

# Drain whole `data: {...}` lines out of `buf`, calling
# _ssehandle_event for each. Returns (remaining_partial_line, done_flag).
# `done_flag` = 1 iff `data: [DONE]` was seen.
# Also tolerates Transfer-Encoding chunked size lines (`42\r\n`) that
# show up inline — they don't start with "data: " so they're skipped.
_ssedrain_lines(buf: array of byte, st: ref _SseState, req: ref AskRequest): (array of byte, int)
{
	start := 0;
	done := 0;
	for(i := 0; i < len buf; i++) {
		if(buf[i] != byte '\n')
			continue;
		# Extract line buf[start:i], strip trailing \r
		end := i;
		if(end > start && buf[end-1] == byte '\r')
			end--;
		line := string buf[start:end];
		start = i + 1;
		if(line == "")
			continue;
		if(!hasprefix(line, "data: "))
			continue;
		data := line[6:];
		if(data == "[DONE]") {
			done = 1;
			break;
		}
		(jv, jerr) := readjsonstring(data);
		if(jerr != nil)
			continue;
		_ssehandle_event(jv, st, req);
	}
	# Anything from `start` onwards is the trailing partial line —
	# return it so the caller carries it forward to the next read.
	if(start < len buf)
		return (buf[start:], done);
	return (array[0] of byte, done);
}

parseopenaisseresponse(body: string, req: ref AskRequest): (ref AskResponse, string)
{
	# Backward-compat: if the server ignored `stream: true` and returned a
	# complete chat.completion object instead of SSE, fall back to the
	# non-streaming parser. Detected by a leading '{' after any whitespace.
	# Some OpenAI-shape backends (e.g. the local Devstral chat_server.py)
	# don't implement streaming and silently return a single JSON body.
	# See tests/llmclient_sse_fallback_test.b.
	stripped := body;
	wsi := 0;
	for(; wsi < len stripped; wsi++)
		if(stripped[wsi] != ' ' && stripped[wsi] != '\t' && stripped[wsi] != '\r' && stripped[wsi] != '\n')
			break;
	if(wsi > 0 && wsi < len stripped)
		stripped = stripped[wsi:];
	if(len stripped > 0 && stripped[0] == '{')
		return parseopenairesponse(body, req);

	# Buffered-body SSE parse — used when the whole response was read
	# in one go (askopenaistream's non-streaming peer, error fallback,
	# or the existing fallback tests). For true incremental streaming,
	# askopenaistream uses _ssehandle_event + _ssebuild_response directly.
	st := ref _SseState("", 0, "", nil, nil, nil);
	lines := splitlines(body);
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		line = stripnl(line);
		if(line == "")
			continue;
		if(!hasprefix(line, "data: "))
			continue;
		data := line[6:];
		if(data == "[DONE]")
			break;
		(jv, jerr) := readjsonstring(data);
		if(jerr != nil)
			continue;
		_ssehandle_event(jv, st, req);
	}
	return _ssebuild_response(st, req);
}

# ==================== Fallback Text Tool Call Parser ====================

# extracttexttoolcalls scans content text for tool calls embedded as text
# when models (e.g. Ollama/Qwen) don't use the structured tool_calls API.
# Supported formats:
#   1. <function=name>\n<parameter=args>\nvalue\n</parameter>\n</function>
#   2. <tool_call>\n{"name": "...", "arguments": {...}}\n</tool_call>
#   3. <|tool_call|>\n{"name": "...", "arguments": {...}}\n<|/tool_call|>
# Returns (remaining_text, list of (id, name, args) tuples).
extracttexttoolcalls(content: string, tooldefs: list of ref ToolDef): (string, list of (string, string, string))
{
	calls: list of (string, string, string);
	remaining := "";
	nextid := 0;

	i := 0;
	while(i < len content) {
		# Try [TOOL_CALLS]/<SPECIAL_66> array (Mistral chat-template
		# leakage when Ollama doesn't translate the special token).
		(matched0, end0, multi) := trytoolcallsarray(content, i);
		if(matched0) {
			for(; multi != nil; multi = tl multi) {
				(mname, margs) := hd multi;
				if(validtoolname(mname, tooldefs)) {
					id := sys->sprint("fallback_%d", nextid++);
					calls = (id, mname, margs) :: calls;
				}
			}
			i = end0;
			continue;
		}

		# Try <function=name> format
		(matched, end, name, args) := tryfunctiontag(content, i);
		if(matched) {
			if(validtoolname(name, tooldefs)) {
				id := sys->sprint("fallback_%d", nextid++);
				calls = (id, name, args) :: calls;
			}
			i = end;
			continue;
		}

		# Try <tool_call> format
		(matched2, end2, name2, args2) := trytoolcalltag(content, i, "<tool_call>", "</tool_call>");
		if(matched2) {
			if(validtoolname(name2, tooldefs)) {
				id := sys->sprint("fallback_%d", nextid++);
				calls = (id, name2, args2) :: calls;
			}
			i = end2;
			continue;
		}

		# Try <|tool_call|> format
		(matched3, end3, name3, args3) := trytoolcalltag(content, i, "<|tool_call|>", "<|/tool_call|>");
		if(matched3) {
			if(validtoolname(name3, tooldefs)) {
				id := sys->sprint("fallback_%d", nextid++);
				calls = (id, name3, args3) :: calls;
			}
			i = end3;
			continue;
		}

		# Not a tool call tag — accumulate as remaining text
		remaining[len remaining] = content[i];
		i++;
	}

	if(calls == nil)
		return (content, nil);

	count := 0;
	for(cl := calls; cl != nil; cl = tl cl)
		count++;
	sys->fprint(stderr, "llmclient: fallback tool parser: extracted %d tool calls from text\n", count);

	# Reverse calls to preserve original order
	rev: list of (string, string, string);
	for(; calls != nil; calls = tl calls)
		rev = hd calls :: rev;

	return (remaining, rev);
}

# tryfunctiontag attempts to parse <function=name>...<parameter=...>...</parameter>...</function>
# starting at position pos in s.
# Returns (matched, end_pos, name, args_json).
tryfunctiontag(s: string, pos: int): (int, int, string, string)
{
	tag := "<function=";
	if(pos + len tag >= len s || s[pos:pos+len tag] != tag)
		return (0, 0, "", "");

	# Find the closing > of <function=name>
	namestart := pos + len tag;
	nameend := namestart;
	while(nameend < len s && s[nameend] != '>')
		nameend++;
	if(nameend >= len s)
		return (0, 0, "", "");
	name := s[namestart:nameend];
	i := nameend + 1;

	# Skip whitespace/newlines
	while(i < len s && (s[i] == '\n' || s[i] == '\r' || s[i] == ' ' || s[i] == '\t'))
		i++;

	# Collect argument value — look for <parameter=...>value</parameter> blocks
	argsobj := "{";
	argfirst := 1;
	while(i < len s) {
		ptag := "<parameter=";
		if(i + len ptag < len s && s[i:i+len ptag] == ptag) {
			# Parse parameter name
			pnamestart := i + len ptag;
			pnameend := pnamestart;
			while(pnameend < len s && s[pnameend] != '>')
				pnameend++;
			if(pnameend >= len s)
				break;
			pname := s[pnamestart:pnameend];
			j := pnameend + 1;

			# Skip leading newline
			if(j < len s && s[j] == '\n')
				j++;

			# Collect value until </parameter>
			endptag := "</parameter>";
			pval := "";
			while(j + len endptag <= len s && s[j:j+len endptag] != endptag) {
				pval[len pval] = s[j];
				j++;
			}
			if(j + len endptag <= len s)
				j += len endptag;

			# Strip trailing newline from value
			while(len pval > 0 && (pval[len pval-1] == '\n' || pval[len pval-1] == '\r'))
				pval = pval[:len pval-1];

			if(!argfirst)
				argsobj += ",";
			argfirst = 0;
			argsobj += jquote(pname) + ":" + jquote(pval);
			i = j;
		} else {
			# Check for </function>
			endtag := "</function>";
			if(i + len endtag <= len s && s[i:i+len endtag] == endtag) {
				i += len endtag;
				break;
			}
			# Skip whitespace between parameters
			i++;
		}
	}
	argsobj += "}";

	return (1, i, name, argsobj);
}

# trytoolcalltag attempts to parse <tool_call>...</tool_call> or <|tool_call|>...</|tool_call|>
# JSON content, starting at position pos in s.
# Returns (matched, end_pos, name, args_json).
trytoolcalltag(s: string, pos: int, opentag, closetag: string): (int, int, string, string)
{
	if(pos + len opentag > len s || s[pos:pos+len opentag] != opentag)
		return (0, 0, "", "");

	# Find the close tag
	j := pos + len opentag;
	bodystart := j;
	while(j + len closetag <= len s && s[j:j+len closetag] != closetag)
		j++;
	if(j + len closetag > len s)
		return (0, 0, "", "");

	body := strip(s[bodystart:j]);
	endpos := j + len closetag;

	# Parse JSON body: {"name": "...", "arguments": {...}}
	(jv, jerr) := readjsonstring(body);
	if(jerr != nil)
		return (0, 0, "", "");

	namev := jv.get("name");
	name := "";
	if(namev != nil) pick nv := namev { String => name = nv.s; }
	if(name == "")
		return (0, 0, "", "");

	argsv := jv.get("arguments");
	args := "{}";
	if(argsv != nil)
		args = argsv.text();

	return (1, endpos, name, args);
}

# trytoolcallsarray: Mistral [TOOL_CALLS]/<SPECIAL_66> marker followed by
# a JSON array of {name, arguments} objects. Used when the chat-template
# special token leaks into chat content — observed with Ollama serving
# Devstral fine-tunes that emit a text preamble before the tool call,
# breaking Ollama's "tool_calls must be the first thing in the assistant
# turn" parser. Returns (matched, end_pos, list of (name, args_json)).
trytoolcallsarray(s: string, pos: int): (int, int, list of (string, string))
{
	# Match either canonical name or special-token text form
	m1 := "[TOOL_CALLS]";
	m2 := "<SPECIAL_66>";
	j := pos;
	if(pos + len m1 <= len s && s[pos:pos+len m1] == m1)
		j = pos + len m1;
	else if(pos + len m2 <= len s && s[pos:pos+len m2] == m2)
		j = pos + len m2;
	else
		return (0, 0, nil);

	# Skip whitespace before the array opener
	while(j < len s && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r'))
		j++;

	if(j >= len s || s[j] != '[')
		return (0, 0, nil);

	# Find matching ']' with depth + string tracking so args containing
	# brackets in quoted strings don't fool us.
	start := j;
	depth := 0;
	inq := 0;
	esc := 0;
	while(j < len s) {
		c := s[j];
		if(esc) {
			esc = 0;
		} else if(inq) {
			if(c == '\\')
				esc = 1;
			else if(c == '"')
				inq = 0;
		} else {
			if(c == '"')
				inq = 1;
			else if(c == '[')
				depth++;
			else if(c == ']') {
				depth--;
				if(depth == 0) {
					j++;
					break;
				}
			}
		}
		j++;
	}
	if(depth != 0)
		return (0, 0, nil);

	body := s[start:j];
	(jv, jerr) := readjsonstring(body);
	if(jerr != nil)
		return (0, 0, nil);

	calls: list of (string, string);
	pick av := jv {
	Array =>
		for(k := 0; k < len av.a; k++) {
			entry := av.a[k];
			if(entry == nil)
				continue;
			namev := entry.get("name");
			name := "";
			if(namev != nil) pick nv := namev { String => name = nv.s; }
			if(name == "")
				continue;
			argsv := entry.get("arguments");
			args := "{}";
			if(argsv != nil)
				args = argsv.text();
			calls = (name, args) :: calls;
		}
	* =>
		return (0, 0, nil);
	}

	# Reverse to preserve original order
	rev: list of (string, string);
	for(; calls != nil; calls = tl calls)
		rev = hd calls :: rev;

	return (1, j, rev);
}

# validtoolname checks whether name matches one of the provided tool definitions.
validtoolname(name: string, tooldefs: list of ref ToolDef): int
{
	for(tl2 := tooldefs; tl2 != nil; tl2 = tl tl2) {
		if((hd tl2).name == name)
			return 1;
	}
	return 0;
}

# ==================== Public Utilities ====================

parsetoolresults(text: string): (list of ref ToolResult, string)
{
	lines := splitlines(text);
	if(lines == nil || hd lines != "TOOL_RESULTS")
		return (nil, "missing TOOL_RESULTS header");

	lines = tl lines;  # skip header
	results: list of ref ToolResult;

	while(lines != nil) {
		# Skip blank lines
		if(hd lines == "" || hd lines == "\r") {
			lines = tl lines;
			continue;
		}

		# Next non-empty line is tool_use_id
		tooluseid := strip(hd lines);
		lines = tl lines;

		# Collect content lines until "---" or end
		contentlines: list of string;
		while(lines != nil && hd lines != "---") {
			contentlines = hd lines :: contentlines;
			lines = tl lines;
		}
		# Skip "---" separator
		if(lines != nil && hd lines == "---")
			lines = tl lines;

		content := joinrev(contentlines, "\n");
		# Trim trailing newlines
		while(len content > 0 && content[len content - 1] == '\n')
			content = content[:len content - 1];

		results = ref ToolResult(tooluseid, content) :: results;
	}

	if(results == nil)
		return (nil, "TOOL_RESULTS contained no results");

	# Reverse to preserve order
	rev: list of ref ToolResult;
	for(; results != nil; results = tl results)
		rev = hd results :: rev;

	return (rev, nil);
}

extracttextcontent(response: string): string
{
	if(!hasprefix(response, "STOP:"))
		return response;

	lines := splitlines(response);
	textlines: list of string;
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(hasprefix(line, "STOP:") || hasprefix(line, "TOOL:"))
			continue;
		textlines = line :: textlines;
	}
	return joinrev(textlines, "\n");
}

messagesjson(msgs: list of ref LlmMessage): string
{
	s := "[";
	first := 1;
	for(; msgs != nil; msgs = tl msgs) {
		m := hd msgs;
		if(!first)
			s += ",";
		first = 0;
		s += "{\"role\":" + jquote(m.role) +
			",\"content\":" + jquote(m.content);
		if(m.sc != "")
			s += ",\"sc\":" + jquote(m.sc);
		s += "}";
	}
	s += "]";
	return s;
}

jsonescapestr(s: string): string
{
	result := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'\\' => result += "\\\\";
		'"' =>  result += "\\\"";
		'\n' => result += "\\n";
		'\r' => result += "\\r";
		'\t' => result += "\\t";
		'\b' => result += "\\b";
		16rc  => result += "\\f";
		* =>
			if(c < 16r20)
				result += sys->sprint("\\u%04x", c);
			else
				result[len result] = c;
		}
	}
	return result;
}

# ==================== HTTP Client ====================
#
# Read loop with no-progress watchdog. Two tunables:
#   HTTP_POLL_MS        — how often main wakes to check the watchdog
#                          channel + progress timer
#   HTTP_NO_PROGRESS_MS — kill the connection if no bytes arrive within
#                          this window
#
# The watchdog is *per quiet period*, not per call: every successful
# read resets the timer. So a 5-minute Ollama call that delivers a
# chunk every few seconds will not trip it; a hung connection that
# stops delivering bytes for >NO_PROGRESS_MS will.
#
# 120s default reflects worst-case cold-prefill on CPU-only Ollama
# with a ~15KB system prompt + tool definitions + history. Measured
# end-to-end (gpt-oss:20b on a mid-2020s x86): cold first-content at
# ~75s, warm at ~3s. Sub-60s would kill legitimate cold turns; >120s
# wastes budget on a real hang. Override via env LLMCLIENT_NO_PROGRESS_MS
# (reserved — currently const for build-time simplicity; if/when an
# env knob is needed, swap to a runtime-resolved global in init()).
#
# On trip, we write "hangup" to the TCP ctl file (devip.c:896 — Inferno
# IP stack closes the socket at the kernel level), which forces the
# in-flight sys->read to fail. The reader thread then deposits its
# final (n, buf) tuple onto a buffered channel and exits. We don't wait
# for it.
HTTP_POLL_MS:        con 200;
HTTP_NO_PROGRESS_MS: con 120000;

# Per-read reader thread: blocks on sys->read, pushes one chunk per
# iteration. Caller's channel must be buffered (capacity >= 1) so a
# final post-hangup tuple can be deposited even if main has bailed.
_httpread(fd: ref Sys->FD, ch: chan of (int, array of byte))
{
	for(;;) {
		buf := array[8192] of byte;
		n := sys->read(fd, buf, len buf);
		ch <-= (n, buf);
		if(n <= 0)
			break;
	}
}

# Common read-with-watchdog loop. Drives _httpread and collects bytes
# until EOF, error, or the no-progress watchdog fires. Returns
# (response, errstr) — errstr non-nil only on timeout (EOF/sys errors
# are normal terminators, surfaced by parse).
_httpreadloop(conn: Sys->Connection): (string, string)
{
	response := "";
	rch := chan[1] of (int, array of byte);
	spawn _httpread(conn.dfd, rch);
	idle_ms := 0;
	for(;;) {
		alt {
		rr := <-rch =>
			(n, rdata) := rr;
			if(n <= 0)
				return (response, nil);
			response += string rdata[0:n];
			idle_ms = 0;
		* =>
			sys->sleep(HTTP_POLL_MS);
			idle_ms += HTTP_POLL_MS;
			if(idle_ms >= HTTP_NO_PROGRESS_MS) {
				if(conn.cfd != nil)
					sys->fprint(conn.cfd, "hangup");
				return (response, sys->sprint(
					"HTTP read no-progress timeout after %d ms (got %d bytes)",
					HTTP_NO_PROGRESS_MS, len response));
			}
		}
	}
	return (response, nil);  # unreachable; satisfies the type checker
}

httppost(host, port, path, headers, body: string): (string, string)
{
	addr := "tcp!" + host + "!" + port;
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("cannot connect to %s: %r", addr));

	contentlen := len array of byte body;
	req := "POST " + path + " HTTP/1.0\r\n" +
		"Host: " + host + "\r\n" +
		"Content-Length: " + string contentlen + "\r\n" +
		headers +
		"Connection: close\r\n" +
		"\r\n" + body;

	data := array of byte req;
	if(sys->write(conn.dfd, data, len data) < 0)
		return (nil, sys->sprint("write failed: %r"));

	(response, rerr) := _httpreadloop(conn);
	if(rerr != nil)
		return (nil, rerr);

	(nil, nil, rbody) := parsehttpresponse(response);
	return (rbody, nil);
}

# Plain-HTTP GET — mirror of httppost with no body/Content-Length.
httpget(host, port, path, headers: string): (string, string)
{
	addr := "tcp!" + host + "!" + port;
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("cannot connect to %s: %r", addr));

	req := "GET " + path + " HTTP/1.0\r\n" +
		"Host: " + host + "\r\n" +
		headers +
		"Connection: close\r\n" +
		"\r\n";

	data := array of byte req;
	if(sys->write(conn.dfd, data, len data) < 0)
		return (nil, sys->sprint("write failed: %r"));

	(response, rerr) := _httpreadloop(conn);
	if(rerr != nil)
		return (nil, rerr);

	(nil, nil, rbody) := parsehttpresponse(response);
	return (rbody, nil);
}

# List the backend's available models via the OpenAI-compatible
# GET /v1/models endpoint. Returns a newline-separated list of model
# ids. Response shape: {"object":"list","data":[{"id":"name",...},...]}.
listmodels(baseurl, apikey: string): (string, string)
{
	if(baseurl == nil || baseurl == "")
		baseurl = "http://localhost:11434/v1";

	(scheme, host, port, path, uerr) := parseurl(baseurl + "/models");
	if(uerr != nil)
		return ("", "models: " + uerr);

	headers := "";
	if(apikey != nil && apikey != "" && apikey != "not-needed")
		headers = "Authorization: Bearer " + apikey + "\r\n";

	respbody: string;
	err: string;
	if(scheme == "https")
		(respbody, err) = httpsget(host, port, path, headers);
	else
		(respbody, err) = httpget(host, port, path, headers);
	if(err != nil)
		return ("", "models: " + err);

	(jv, jerr) := readjsonstring(respbody);
	if(jerr != nil)
		return ("", "models: parse error: " + jerr);
	if(jv == nil)
		return ("", "models: empty response");

	datav := jv.get("data");
	if(datav == nil)
		return ("", "models: no data field");

	out := "";
	pick da := datav {
	Array =>
		for(i := 0; i < len da.a; i++) {
			idv := da.a[i].get("id");
			if(idv != nil)
				pick ids := idv {
				String =>
					out += ids.s + "\n";
				}
		}
	}
	return (out, nil);
}

# TLS variant of _httpread: reads through the TLS wrapper. Same
# contract (buffered channel, deposits one tuple per chunk + a
# terminator on EOF/err).
_httpsread(tc: ref Conn, ch: chan of (int, array of byte))
{
	for(;;) {
		buf := array[8192] of byte;
		n := tc.read(buf, len buf);
		ch <-= (n, buf);
		if(n <= 0)
			break;
	}
}

# Same watchdog shape as _httpreadloop but for TLS. The TLS layer
# wraps conn.dfd; writing "hangup" to conn.cfd closes the underlying
# TCP socket, which makes the in-flight tc.read fail (TLS sees socket
# error and surfaces it).
_httpsreadloop(conn: Sys->Connection, tc: ref Conn): (string, string)
{
	response := "";
	rch := chan[1] of (int, array of byte);
	spawn _httpsread(tc, rch);
	idle_ms := 0;
	for(;;) {
		alt {
		rr := <-rch =>
			(n, rdata) := rr;
			if(n <= 0)
				return (response, nil);
			response += string rdata[0:n];
			idle_ms = 0;
		* =>
			sys->sleep(HTTP_POLL_MS);
			idle_ms += HTTP_POLL_MS;
			if(idle_ms >= HTTP_NO_PROGRESS_MS) {
				if(conn.cfd != nil)
					sys->fprint(conn.cfd, "hangup");
				return (response, sys->sprint(
					"HTTPS read no-progress timeout after %d ms (got %d bytes)",
					HTTP_NO_PROGRESS_MS, len response));
			}
		}
	}
	return (response, nil);
}

httpspost(host, port, path, headers, body: string): (string, string)
{
	if(tlsmod == nil) {
		tlsmod = load TLS TLS->PATH;
		if(tlsmod == nil)
			return (nil, "cannot load TLS module");
		terr := tlsmod->init();
		if(terr != nil)
			return (nil, "TLS init: " + terr);
	}

	(ok, conn) := sys->dial("tcp!" + host + "!" + port, nil);
	if(ok < 0)
		return (nil, sys->sprint("cannot connect to %s: %r", host));

	config := tlsmod->defaultconfig();
	config.servername = host;

	(tc, cerr) := tlsmod->client(conn.dfd, config);
	if(cerr != nil)
		return (nil, "TLS: " + cerr);

	contentlen := len array of byte body;
	req := "POST " + path + " HTTP/1.0\r\n" +
		"Host: " + host + "\r\n" +
		"Content-Length: " + string contentlen + "\r\n" +
		headers +
		"Connection: close\r\n" +
		"\r\n" + body;

	data := array of byte req;
	if(tc.write(data, len data) < 0) {
		tc.close();
		return (nil, "TLS write failed");
	}

	(response, rerr) := _httpsreadloop(conn, tc);
	tc.close();
	if(rerr != nil)
		return (nil, rerr);

	# Check for HTTP error status
	(status, nil, rbody) := parsehttpresponse(response);
	if(status != "" && !hasprefix(status, "HTTP/1.1 200") && !hasprefix(status, "HTTP/1.0 200")) {
		if(rbody != "")
			return (nil, "HTTP error: " + strip(status) + ": " + rbody);
		return (nil, "HTTP error: " + strip(status));
	}

	return (rbody, nil);
}

# TLS GET — mirror of httpsget's POST sibling with no body.
httpsget(host, port, path, headers: string): (string, string)
{
	if(tlsmod == nil) {
		tlsmod = load TLS TLS->PATH;
		if(tlsmod == nil)
			return (nil, "cannot load TLS module");
		terr := tlsmod->init();
		if(terr != nil)
			return (nil, "TLS init: " + terr);
	}

	(ok, conn) := sys->dial("tcp!" + host + "!" + port, nil);
	if(ok < 0)
		return (nil, sys->sprint("cannot connect to %s: %r", host));

	config := tlsmod->defaultconfig();
	config.servername = host;

	(tc, cerr) := tlsmod->client(conn.dfd, config);
	if(cerr != nil)
		return (nil, "TLS: " + cerr);

	req := "GET " + path + " HTTP/1.0\r\n" +
		"Host: " + host + "\r\n" +
		headers +
		"Connection: close\r\n" +
		"\r\n";

	data := array of byte req;
	if(tc.write(data, len data) < 0) {
		tc.close();
		return (nil, "TLS write failed");
	}

	(response, rerr) := _httpsreadloop(conn, tc);
	tc.close();
	if(rerr != nil)
		return (nil, rerr);

	(status, nil, rbody) := parsehttpresponse(response);
	if(status != "" && !hasprefix(status, "HTTP/1.1 200") && !hasprefix(status, "HTTP/1.0 200")) {
		if(rbody != "")
			return (nil, "HTTP error: " + strip(status) + ": " + rbody);
		return (nil, "HTTP error: " + strip(status));
	}
	return (rbody, nil);
}

parsehttpresponse(response: string): (string, string, string)
{
	# Find status line
	statusend := 0;
	for(; statusend < len response; statusend++)
		if(response[statusend] == '\n')
			break;
	if(statusend == 0)
		return ("", "", "");

	status := response[0:statusend];

	# Find headers end (double newline)
	headersend := statusend + 1;
	for(; headersend < len response - 1; headersend++) {
		if(response[headersend] == '\n' &&
		   (response[headersend+1] == '\n' || response[headersend+1] == '\r'))
			break;
	}

	headers := "";
	if(headersend > statusend + 1)
		headers = response[statusend+1:headersend];

	# Find body
	bodystart := headersend + 1;
	if(bodystart < len response && response[bodystart] == '\r')
		bodystart++;
	if(bodystart < len response && response[bodystart] == '\n')
		bodystart++;

	bodys := "";
	if(bodystart < len response)
		bodys = response[bodystart:];

	return (status, headers, bodys);
}

parseurl(url: string): (string, string, string, string, string)
{
	scheme := "http";
	port := "80";
	i: int;

	if(len url > 7 && str->tolower(url[0:7]) == "http://") {
		url = url[7:];
	} else if(len url > 8 && str->tolower(url[0:8]) == "https://") {
		scheme = "https";
		port = "443";
		url = url[8:];
	} else {
		return ("", "", "", "", "invalid URL");
	}

	# Find path
	path := "/";
	for(i = 0; i < len url; i++) {
		if(url[i] == '/') {
			path = url[i:];
			url = url[0:i];
			break;
		}
	}

	# Find port
	host := url;
	for(i = 0; i < len url; i++) {
		if(url[i] == ':') {
			host = url[0:i];
			port = url[i+1:];
			break;
		}
	}

	return (scheme, host, port, path, nil);
}

# ==================== Helpers ====================

readjsonstring(s: string): (ref JValue, string)
{
	bio := bufio->aopen(array of byte s);
	if(bio == nil)
		return (nil, "cannot create buffer");
	return json->readjson(bio);
}

jquote(s: string): string
{
	return "\"" + jsonescapestr(s) + "\"";
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

stripnl(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[:len s - 1];
	return s;
}

splitlines(s: string): list of string
{
	lines: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			lines = s[start:i] :: lines;
			start = i + 1;
		}
	}
	if(start < len s)
		lines = s[start:] :: lines;

	# Reverse
	rev: list of string;
	for(; lines != nil; lines = tl lines)
		rev = hd lines :: rev;
	return rev;
}

replaceall(s, old, new: string): string
{
	result := "";
	i := 0;
	while(i <= len s - len old) {
		if(s[i:i+len old] == old) {
			result += new;
			i += len old;
		} else {
			result[len result] = s[i];
			i++;
		}
	}
	while(i < len s) {
		result[len result] = s[i];
		i++;
	}
	return result;
}

joinrev(l: list of string, sep: string): string
{
	# Reverse the list first, then join
	rev: list of string;
	for(; l != nil; l = tl l)
		rev = hd l :: rev;

	result := "";
	first := 1;
	for(; rev != nil; rev = tl rev) {
		if(!first)
			result += sep;
		first = 0;
		result += hd rev;
	}
	return result;
}

estimatetokens(s: string): int
{
	n := len s;
	if(n == 0)
		return 0;
	return n / 4;
}

extracttoolargs(inputjson: string): string
{
	(jv, jerr) := readjsonstring(inputjson);
	if(jerr != nil)
		return inputjson;

	pick obj := jv {
	Object =>
		# Assembly order is "command first, args second, then any
		# remaining string properties in JSON order."
		#
		# Why: tools like task and memory use a `{command, args}`
		# schema where the value of `args` is itself a key=value
		# string. exec() splits on first whitespace to extract the
		# command, so command must come first.
		#
		# Smaller models (notably gpt-oss:20b) frequently emit the
		# object in args-first order despite the schema declaring
		# command first. A naive JSON-encounter-order join would
		# produce "args command" — wrong. Hence the special-case
		# ordering here.
		#
		# Reproduced in the eval harness as the "Tool X has failed 3
		# consecutive times" loop; see pdfinn/infernode-eval-harness
		# FINDINGS.md §F3.
		cmdval := "";
		hascmd := 0;
		argsval := "";
		hasargs := 0;
		nprops := 0;
		# `others` collected in reverse — reversed back into JSON
		# order below before joining.
		others_rev: list of string;
		for(ml := obj.mem; ml != nil; ml = tl ml) {
			(name, val) := hd ml;
			nprops++;
			s := "";
			pick sv := val {
			String => s = sv.s;
			* => s = val.text();
			}
			if(name == "command") {
				cmdval = s;
				hascmd = 1;
			} else if(name == "args") {
				argsval = s;
				hasargs = 1;
			} else {
				others_rev = s :: others_rev;
			}
		}
		# Legacy shortcut: tool's whole surface is a single `args`.
		if(hasargs && nprops == 1)
			return argsval;
		# Reverse others_rev once so we can iterate in JSON-encounter
		# order.
		others: list of string;
		for(orl := others_rev; orl != nil; orl = tl orl)
			others = hd orl :: others;
		# Forward-build the final result in canonical order:
		#   command first, args second, remaining string props in JSON order.
		result := "";
		if(hascmd)
			result = cmdval;
		if(hasargs) {
			if(result != "")
				result += " ";
			result += argsval;
		}
		for(ofl := others; ofl != nil; ofl = tl ofl) {
			if(result != "")
				result += " ";
			result += hd ofl;
		}
		return result;
	}
	return inputjson;
}

# List helper functions (for tool call delta accumulation)

listlen(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

listget(l: list of string, idx: int): string
{
	for(i := 0; l != nil; l = tl l) {
		if(i == idx)
			return hd l;
		i++;
	}
	return "";
}

listset(l: list of string, idx: int, val: string): list of string
{
	result: list of string;
	i := 0;
	for(ol := l; ol != nil; ol = tl ol) {
		if(i == idx)
			result = val :: result;
		else
			result = hd ol :: result;
		i++;
	}
	# Reverse
	rev: list of string;
	for(; result != nil; result = tl result)
		rev = hd result :: rev;
	return rev;
}

append(l: list of string, val: string): list of string
{
	# Append to end by reversing, prepending, reversing
	rev: list of string;
	for(ol := l; ol != nil; ol = tl ol)
		rev = hd ol :: rev;
	rev = val :: rev;
	result: list of string;
	for(; rev != nil; rev = tl rev)
		result = hd rev :: result;
	return result;
}
