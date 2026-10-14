# precomposed letters: for each accent command, pairs of a letter and
# that letter with the accent (generated from Unicode's compositions)
accents := array[] of {
	("'", "aáeéiíoóuúyýAÁEÉIÍOÓUÚYÝcćCĆnńNŃsśSŚzźZŹgǵGǴrŕRŔlĺLĹkḱKḰwẃWẂmḿMḾpṕPṔ"),
	("`", "aàeèiìoòuùyỳAÀEÈIÌOÒUÙYỲnǹNǸwẁWẀ"),
	("^", "aâeêiîoôuûyŷAÂEÊIÎOÔUÛYŶcĉCĈsŝSŜzẑZẐgĝGĜhĥHĤjĵJĴwŵWŴ"),
	("\"", "aäeëiïoöuüyÿAÄEËIÏOÖUÜYŸtẗhḧHḦwẅWẄxẍXẌ"),
	("~", "aãeẽiĩoõuũyỹAÃEẼIĨOÕUŨYỸnñNÑvṽVṼ"),
	("=", "aāeēiīoōuūyȳAĀEĒIĪOŌUŪYȲgḡGḠ"),
	(".", "aȧeėoȯyẏAȦEĖIİOȮYẎcċCĊnṅNṄsṡSṠzżZŻgġGĠrṙRṘtṫTṪdḋDḊhḣHḢwẇWẆxẋXẊbḃBḂmṁMṀpṗPṖfḟFḞ"),
	("c", "eȩEȨcçCÇnņNŅsşSŞgģGĢrŗRŖlļLĻtţTŢdḑDḐkķKĶhḩHḨ"),
	("v", "aǎeěiǐoǒuǔAǍEĚIǏOǑUǓcčCČnňNŇsšSŠzžZŽgǧGǦrřRŘlľLĽtťTŤdďDĎkǩKǨhȟHȞjǰ"),
	("u", "aăeĕiĭoŏuŭAĂEĔIĬOŎUŬgğGĞ"),
	("H", "oőuűOŐUŰ"),
	("k", "aąeęiįoǫuųAĄEĘIĮOǪUŲ"),
	("r", "aåuůyẙAÅUŮwẘ"),
	("d", "aạeẹiịoọuụyỵAẠEẸIỊOỌUỤYỴnṇNṆsṣSṢzẓZẒrṛRṚlḷLḶtṭTṬdḍDḌkḳKḲhḥHḤwẉWẈbḅBḄmṃMṂvṿVṾ"),
	("b", "nṉNṈzẕZẔrṟRṞlḻLḺtṯTṮdḏDḎkḵKḴhẖbḇBḆ"),
};
