implement LibsecKatTest;

#
# Keyring's AES-256-GCM, AES-256-CBC and SHA-256 (libsec underneath)
# against answers worked out elsewhere: OpenSSL's for GCM
# (tests/host/gcm/vectors.txt, 438 cases: 128-, 192- and 256-bit keys,
# IVs of 12 bytes and others, every length across the blocks), NIST SP
# 800-38A F.2.5 for CBC, FIPS 180-4's examples (a million "a"s among
# them) for SHA-256.  Wherever it runs -- the emulator, a native kernel
# on a core with the ARMv8 instructions or without -- the answers are
# the same, so a path through AESE, PMULL or SHA256H that gives anything
# else fails here, as one checked only against itself would not.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

LibsecKatTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/libsec_kat_test.b";
VECTORS: con "/tests/host/gcm/vectors.txt";
vectors := VECTORS;	# or the argument naming them (a board, whose tree is elsewhere)

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

unhex(s: string): array of byte
{
	if(s == "-")
		return array[0] of byte;
	b := array[len s/2] of byte;
	for(i := 0; i < len b; i++){
		v := 0;
		for(k := 0; k < 2; k++){
			c := s[2*i+k];
			if(c >= 'a')
				v = v*16 + c - 'a' + 10;
			else
				v = v*16 + c - '0';
		}
		b[i] = byte v;
	}
	return b;
}

hex(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s += sys->sprint("%.2ux", int b[i]);
	return s;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# 27 of the 438 kept in the source, so a kernel with no file of them
# (its root is compiled in) still checks AES-256-GCM at every length
# that crosses a block, and AES-128 and -192, and IVs of other lengths.
# Each: key iv aad data ciphertext tag, "-" for empty.
builtin := array[] of {
	"6efaf2dbeaa726c3b49bf817ff391eb37f3e9bd0be0ecce3cb447989fbb1080b 8f6dbe8270d3a598fa66f07b c8 - - 38163824cc06aad7e0fd7374facc0800",
	"1b6d7c4938daf8b9a76230f3427956091e1e3d98fd803645b0e4447a53588e17 71d160a941557c4ec87abe49 748c3c548f5337597ac38b863088bd280d59b24e3b924433cb4b7343aced0eb9 21 5a 198608b5992276ebe3af2b01face546b",
	"dda6980cd3313c8557f68ccb897e3b045807d7f52c4c2740468574ed5ff565b4 68fc1128eedeede8753448c8 e106 c983cff9fa82abe53b21fe5e676e23 c1267cd3014abe2f40adac8cdc23dc f60ff608b85eacd880312ffac5aa1458",
	"dd6abaaab444f1c8cd66a03954307ac3a4d8e76d5c0ceececf38ae39356beca0 62266311e247d59e8c65dbd7 10b9ad5406f5c8e1579ff662e94be80ee1 9c3e064a835b8bbdbbd0f16a9c6ccc57 00e409b1e7f808f577cb32624cc776d2 90670a2bb7ced26436bfd115b556744a",
	"74a6fdbc3e40718f039b7d79196675d4d76412a50f2d620e8880ccf71c6b9f54 29b7553823775e82b177fd00 459a 391df65cd5ca14944adaff39e208f0598b 13191f9dde9ae05438442433b13aa5f9e9 564d0d2ebe8ac4fd44de47d28f834b02",
	"7022d3da7c1f126f8549e5b59f126e48bbfec701ec5941c2372f22d7ee48d83e f9f26f25aa1f2d63345d06a3 116fcbf931e57faffb07b8c60b58ca89 0d35e32410ec3d95a9e4bcfddea61cbec1f5512ee9622757d16d734d8d27a2 ea2fb51739340c7042e443b9033d846f94c2a852050b5efee61e410c2d28eb 32b31a0f9a130032012b02787d1acb43",
	"2197a9826a593f6e5ec10ce3ee2c505590d75611f5ca919e5f1429f3f135ff12 47db72ca08f3ed07652e097d 4e5cb4b582d49d6c6003982ced48e29c 2e7c69b1777c1887f332dfe01d82ba9dd24febdf2afd9061666dacb486bacc8b 919a5c27f85887769b0787235ad091a39f0907f5c4675844c467fd752ad08333 230c26f517f120755520196cd927daff",
	"9b5136102bbe335c1836b0cb94d38428216141369f6ed4dd66e36d9c6ce4395e b4701b8b9a6cb57fb0e02da3 0ab019839b8c1601a4f87f5acc 131a6fa43bc8b8160e84d3b80a1a09d9245db36d820d34b4bca30eb8834074b35f e1cc594f174e8c942283fb931274d171822d9ef6d544962bd400cfcdfa95b2a285 2a3539b16421e5516e357c8dfd372df4",
	"d398354584a70d0619e62e59da9582aefdfb199ff1f9fe0387204fa5176e0511 b9e6409fb782d89a9ccbcc7d 3aef9092ed8aab56f558c8b63dd4b50c42 edb246b91768dff086e7f15e391e61a9a0c690c7b367d24786a2415fa90800b6adf096bac114bef5ef513133294f338050e3674c67a93b4f2a6ae1b77eea29 11929fb407f385ec46a401d763711dd777252dd1e133e543c12da5e46a34e19128d0e9c83fd160dd04559a83c43de4e94a0cd2ea3422e1736980d320eb93ae 6c130543c490d4fd4d8dab15138d1ad5",
	"6a6854bafccef55c13cb4ba143123f22e67125d06956b56a54fce42ddc38ebe7 314988e66c1e925fe3e0eda0 567ba66af5aa5005501a5b02fdcac5897648a3ecf8f9d794435b5aa1a4df8a0817 02f5535cd7f660939977ea34e48e9c3657e5980ac3362bbda2857495fb8a8f65e3318747b9a7d45e5e9f516936a500b5b5e00324a6e063e40f8719604fab0cc7 ca54b9c059b249c04bae21ccc6934d682f654cf7adafe3244abb76ea2860cb18ea2a99f1193e836cee803aef66ea56f33e2708147ee807593f6d77955ce86795 3e4dee8914b526360b00ea0fbd1b2b12",
	"8d6e7e0f669c49cef28b189acded681490c917e715bb374ecba21e100af94691 48b3858646964882abd7a8ff - 65fec488b5ae304ee3d7112dfd57f0066093a2e9cecc2fcff1d57add41bb192a1c53246529841a1a819c28e79c8d58ebbd1b2550b863492778de8e5b154e5042fb 908539f29a92641bde21742b978c109c9c25e5e811dba7cfe344b13ccc4688c0ad2313aa9b7544125cfc02df82b1785fb28922acf685cccfd6473233ae9b309ff9 6e74cee8e217f279ecc0c62f2ddd76c7",
	"985dfa47428db868d42fa4428c78c409c58c795c7fa2b21f2a85c955fa36c9ed dc2d498b36160be69906c05f - 6a02c050f4635e3c74bde33eca119c675a8f082fd2b92a735b759374548186c469f5171e67d29396054a7b8be31dfc44bcf3b780120a32db298efbb869392c7742249605b1c960c6149b69fcadc07ecfe8dcbb83cace53337c805bbe09e3a293743ebc1d6d54209a837866392c5ff105d5f2a0d7dc2ee0a4ea9d8dcdd31bdc222bfc4de7332eab77165a562b6bbe39c5a8b9997a9b3f5aa83cfa6952d70ae2c6c1cae24e76d41dd7f5a8cf1fec80c564b92263c5c34cc9c6ffe9c38278ad178383c28fc9c080411fbb71a519a4ec7d2ad2e107b4efb3d13fa11f9f827cf892060bb7bf436ba0151f4361d9eb292c6cd2e6ad701399c860b1fa00834416aafa ff730a6d590985832d88233177c7b3555551e89cc4adb1f22669b0b96c630bc80ce8b4c54dedef9ad2bad9bfb6dd2e1985e658d68a9c16463a2e9542c0e9310be1d0ad113a9979440928360d5db7c2d1918de2f381ace817cc839e014eec5f7c3f4d9b9ce9f7b31ee910be9d5d7849d5b550fa572590d15d5ce782f1aa7756a451a3aaeba67cdb8b3fd412490cf806504c48a64b3dad4e101c9b81fc01eb1be81ce5655e4db348b91c40984e23386d240ee290d3e4fd20ed5d7761c1c57e06f417b058fb50fac48d424f81b97e3257c74e0cb5033f5a8e7e253121d427e0c8d96fd6f1352ed992c14d07f3a9b99b99ab7e3210a81cd3ae40c5490e7a1eee01 0c5763cf99fd1e552e99bd74db965c7b",
	"395442f3fda994d0159a7d08da5e8d3b02832d91060cdb0e400bde41a063805c c88d547d15cd68d04f7c5b3c 6ad9b8963b9355ea68b81744c6bda8fbe88b8f192ace0872891992e4446d3f6cc5 53f1810492faaf61fb9b42cfd043e14c5e1b9d7e42d3d27f241ea3d9f869794fe803898a1dfd6c4050cdc8888674cda528064e5ab376104225dd60a02600c8b949c4ad19fc9cef9fc206501b5f56025edd8610b024017b65d138a92dc9aec75102b6b204417b623ac4b9b306da6512a0ba20f9ed256dc781d60902f7855bc82b56462afb66d19161aa5708ee09b34b7e6487e0f6a6e058d7bf125c52c9f399d166963634e28f54daeae4d9e1348132b0e1e886784ef9d9fd7e795cd858b97e253ebba43375e55408a2e98d81b2fd69e0df8f5e023a521a6963ed1d330f54172b3c5f5eab1218e19dbe0eb5a7014863bd6044c62ea888f818c06f53c0423b5054 7902bc50400403e2f8e5693becb3cfac712aa0365a65fad195d4f63e3500501e5278b3a381b357e82ebac684010cc17c8217f3c0c4184d252428c9e77deccb208b3f03d303dae682db3eb5e1c0c349a42739012e7268e27a8d9ebc847b4568cd7b7285709b9c73f5dda353d7581f43d44aae5dae8abcf75604495d44aa7f5e4c6ecc28db69699f5ba8264d5937157d6853cd7daabf7b544dbf4bc61d9cecafa80f71de7aa0226f97db3fcdf9f0bde455d8ab9dd6349074638d4d44570f7212ab8c0ac609969da0825a2d0ee6c0e425f39da6d7886961a315d4143230bb625694adba519a47c2602d58826af3e72d78035ebdd86a94bb35744ada4840a3d31f9b 166e5241b67f345dca5e44f7058fab78",
	"8376bf2904eb7d3139e685884b868f4efbac7b64be5dbcec6ffcca84e5768a68 1c19e6b9ae6c1fb8 257a08672cae172a7eed53d023c075b136889e4d - - 5cb59f0c2c8670517b732e5efdb57319",
	"2d66ee4053d5504cdd1e1f097a5e18067408ff7999bf1ec94c9cb44b70fd8e42 488ee5cb01e4b74f 02cf3d68c25e6857b761fde86b317a172c1e6f52 94 fa 55dbe644d160b271f28d9613335e6651",
	"36f1fa605db6c3b229185acbf87c46063944db856ce0cc8c5313d86129725e87 d88ce0bbe70c5bde da53c6246039e013357f6fc927fad38a03cc688f 561262a0fb7c09684e7e05c66e1da28e 8bd89155db9019f601fbe18fd8412edd ec89437d459c8d8f309f999ef9e47f3a",
	"5ed99e3173a6ba5b7b18313155bece1faea634edcc7d0291f9966cbf5e9e6471 de4515adcf6be5bf 0f11c5b0626ddce90ba9fb9d871e96b8c2af65e8 88eb9231fb4566b9618f00b5afcfc44600464b210ff448d515e53d3b1918d4f143 8964e14cde9fb1463657233dc9f129bdfe0e7b53384f310dc1b01e074b36649970 0cf8a2d32d3c3159be4f6c30b0a3c746",
	"91d8cdc310411e7ec27378a661c93518 7c07e4d5636e9bc3c400b272 44b8 - - d5e683c9a70c6499632beaaacc428ed2",
	"ea6768f15fccb4662f4da332c49d16d9 4d076c09d2750167 338b9dd579c941d40699b1be35ea39afa723f3c3 - - 3bda0f17dde2bfde3c6f43d5ffbb3a63",
	"d2c4e25a59657a7cebee34a437d2cc24 ce341dbcd20392fed8b7dbea2f7ce757 40e04f16d235c6b2f69fc48c24cfa840f8b63d18 - - 9c463f9aad4e55ae5ae591b13639018f",
	"ff7d08f2d2257fe341768fc7fbb15b96 569bd8a9766a3cd4f5e7d7bedd5f777a7e0130553119d955770bc3dab1e4e02f42ae8c3e72b76e20c6ff2c97cf0a8291d150d07bbdabeab3e84c8d41 e7478780fa60f43e85d73957da4e469251936142 - - 8cc6ff9251c006b158c6920dc5b9f18f",
	"566cbc0a71e31fe6bb7c4133602a6e39 bddc5d63c2b319b2789ce36653caa7b8f5dcbfe8a3ae3a0e1343bc0e92366e368c9fbb32f609104ea4c1119f0087aaf9cf06c0adce2573280ca3df0ba7dbc43d39328c07733e6c3aa5255d0e868c5b6ff808cfe85bbf02387a9267f937b078472bedda5ea64ae51b01ca95868b66ff8e649891dc96a0de1c21b82947a2f65c0b c6cd483162a2dba1e7d313f775daf40c27ae0cf8 - - 4dcf589de7c57ceed80ff4e06f2a3139",
	"58f9739a5e09cf0a1f15debecf9711260df506ca1902f5d0 68c5e45196aa3e8c86e93c32 fe76739e7066030dc5e5c84c3449b03edc - - b79df6eb9f360750d91c38230dac798b",
	"ca016f614017a68800c425af5f777c9a9693804bfd3b8fcd e76714a960fb061d 695df6d8180cfa1f2409ffa7bd4bae848e8f4d19 - - eb6135c7219cd0937d245525e4b5c671",
	"112644f50055605871509d40b064e497b9fa38539c1772ab 753887e0c63e4bb71294b3db5df6aa7a 2d55d096a99599dfdd9f316dfedf6dfc04f082a1 - - 3f7435b044f9795feaa58db762b56e9a",
	"11653af2793f54c33474cf9ea2e6bd49f5e380b3301777f6 545a4475972905e0216c6ae468e6cd1365282357ed327b17e84f4a913d5fb63923e929cfd1a1577b87a61052ee4bfcabd25785ea52320d63ee1be8ad 1caf5af6d1ce3154d21582e6d9cb461ad38d4437 - - 8c81cb0978e07c37e102a5c0b9ec7185",
	"a49afa0f66ae7e471ce340ff5862f4570da61827972a47bf 77e4131686960b7532e48f13e7dc7df89f43e2dccc4fcd67d528da96432d23c6bff442a1ac08426b20a18d58430c4ff403e6f69bf3d075ddec7344539bd79317936c91eb14d3b2ee68982a35cb50882235edc2dca1707d117698e7e1053b25538f204f5e3062feed5cb24ab944722a03c3a59c7f85cd6898ec962fed6a8f5274 cb9b14adea57cdaaedb753be786c76dbcafa8333 - - 581669bfea9c1073b3f7478fb9e9f329",
};

# one vector: nil, or what was wrong
gcm1(fl: list of string): string
{
	key := unhex(hd fl); fl = tl fl;
	iv := unhex(hd fl); fl = tl fl;
	aad := unhex(hd fl); fl = tl fl;
	pt := unhex(hd fl); fl = tl fl;
	ct := unhex(hd fl); fl = tl fl;
	tag := unhex(hd fl);
	(gct, gtag) := kr->aesgcmencrypt(kr->aesgcmsetup(key, iv), pt, aad);
	if(!same(gct, ct) || !same(gtag, tag))
		return sys->sprint("key %d, iv %d, aad %d, data %d bytes: not OpenSSL's", len key, len iv, len aad, len pt);
	back := kr->aesgcmdecrypt(kr->aesgcmsetup(key, iv), ct, aad, tag);
	if(len pt != 0 && !same(back, pt))
		return sys->sprint("key %d, iv %d, data %d bytes: not opened", len key, len iv, len pt);
	return nil;
}

testGCM(t: ref T)
{
	n := bad := 0;
	for(i := 0; i < len builtin; i++){
		(nil, fl) := sys->tokenize(builtin[i], " ");
		n++;
		if((e := gcm1(fl)) != nil && bad++ < 5)
			t.error(sys->sprint("built-in vector %d: %s", i, e));
	}
	f := bufio->open(vectors, Bufio->OREAD);
	if(f != nil){
		while((line := f.gets('\n')) != nil){
			(nf, fl) := sys->tokenize(line, " \t\n");
			if(nf != 7 || hd fl != "gcm")
				continue;
			n++;
			if((e := gcm1(tl fl)) != nil && bad++ < 5)
				t.error(sys->sprint("vector %d of %s: %s", n - len builtin, vectors, e));
		}
		t.assert(n >= len builtin + 438, sys->sprint("%d vectors read", n));
	}
	t.asserteq(bad, 0, "AES-GCM gives OpenSSL's ciphertext and tag, and opens them");
	t.log(sys->sprint("%d GCM vectors", n));
}

# NIST SP 800-38A F.2.5 (CBC-AES256.Encrypt) and F.2.6 (Decrypt)
testCBC(t: ref T)
{
	key := unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
	iv := unhex("000102030405060708090a0b0c0d0e0f");
	pt := unhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
	want := "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b";
	b := array[len pt] of byte;
	b[0:] = pt;
	kr->aescbc(kr->aessetup(key, iv), b, len b, Keyring->Encrypt);
	t.assertseq(hex(b), want, "SP 800-38A F.2.5: AES-256-CBC encrypts to NIST's ciphertext");
	kr->aescbc(kr->aessetup(key, iv), b, len b, Keyring->Decrypt);
	t.assert(same(b, pt), "F.2.6: and decrypts back");
}

sha(m: array of byte): string
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(m, len m, d, nil);
	return hex(d);
}

# FIPS 180-4's examples (NIST's SHA256.pdf, and the million "a"s)
testSHA256(t: ref T)
{
	t.assertseq(sha(array of byte "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256(\"abc\")");
	t.assertseq(sha(array[0] of byte), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of nothing");
	t.assertseq(sha(array of byte "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256 of the 448-bit message");
	a := array[1000000] of {* => byte 'a'};
	t.assertseq(sha(a), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "SHA-256 of a million \"a\"s");
	# the same million fed in pieces that cross the blocks unevenly
	st: ref Keyring->DigestState;
	for(o := 0; o < len a; ){
		k := 1 + ((o % 1000) * 7919) % 1000;
		if(o + k > len a)
			k = len a - o;
		st = kr->sha256(a[o:o+k], k, nil, st);
		o += k;
	}
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, d, st);
	t.assertseq(hex(d), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "and in uneven pieces");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
		else
			vectors = hd a;
	run("Libsec/AESGCM", testGCM);
	run("Libsec/AESCBC", testCBC);
	run("Libsec/SHA256", testSHA256);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
