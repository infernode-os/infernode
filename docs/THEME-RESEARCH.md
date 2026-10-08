# Xenith's colours and type: the research behind them

Xenith ships two themes made for reading text all day: `glenda`, Plan 9's
acme to the pixel, the light theme to prefer, and `xenith`, the dark theme.
This is the evidence they were measured against and the sources for it, so
that a later change can be argued from the same ground.

The review covered display polarity (dark on light against light on dark),
luminance and colour contrast, visual fatigue, and typography. Over a hundred sources
were checked against PubMed, Crossref or the paper itself; those known only
from other papers' reference lists are marked so below.

## What the evidence supports

Strongest first.

1. **Luminance contrast is what makes text readable; colour cannot stand
   in for it.** Text that differs from its background only in hue reads
   poorly, and a little luminance contrast makes the hue irrelevant
   (Legge et al. 1990; Knoblauch et al. 1991; Penkelink & Besuijen 1996).
   Every colour that is read as text must contrast with its background on
   lightness alone; hue only tells categories apart.

2. **Past a modest contrast, more does not help.** Cutting contrast tenfold
   slowed reading by less than half (Legge, Rubin & Luebker 1987). Fluent
   reading needs roughly ten times a reader's contrast threshold
   (Whittaker & Lovie-Kitchin 1993). Off-black on off-white loses nothing
   for normal vision; the headroom above that is for older eyes, glare and
   small type.

3. **Hue barely matters once contrast is fixed; saturation is what people
   dislike.** "Any desaturated colour combination" was satisfactory
   (Pastoor 1990); Hall & Hanna (2004), Lin (2003) and Humar et al. (2014)
   agree.

4. **Dark text on a light ground reads better, and screen luminance is the
   reason, not polarity.** With overall luminance matched the advantage
   goes away (Buchner, Mayr & Brandt 2009): a bright screen narrows the
   pupil and sharpens the retinal image (Taptagaporn & Saito 1990;
   Piepenbrock et al. 2014b). The advantage holds for younger and older
   readers (Piepenbrock et al. 2013), grows as type gets smaller
   (Piepenbrock et al. 2014a), and is largest in a dark room (Dobres,
   Chahine & Reimer 2017). The effects are real but modest, and largest
   near the limits of what can be seen.

5. **Eye strain mostly is not about colour.** It comes from blinking less,
   near work, uncorrected refraction, glare and long sessions (Rosenfield
   2011; Sheppard & Wolffsohn 2018; Wolffsohn et al. 2023). Controlled
   studies of up to about an hour find no difference in fatigue between
   polarities. Blue-blocking lenses do not reduce eye strain (Singh et al.
   2021, a randomised trial; Singh et al. 2023, Cochrane). Blue light's
   effect on sleep follows brightness more than colour (Chang et al. 2015;
   Nagare et al. 2019). No study shows a cream or warm tint reduces fatigue
   (Griffiths et al. 2016).

6. **Syntax colouring has little or no effect on understanding code**
   (Sarkar 2015; Hannebauer, Hesenius & Gruhn 2018, n=390; Beelders & du
   Plessis 2015). Acme's lack of it is defensible; Xenith keeps it out.

## Where a dark theme is justified

- **Light scatter in the eye.** Readers with cataract or other cloudy media
  read faster with light text on dark (Legge et al. 1985b; Rubin & Legge
  1989; Legge, Rubin & Schleske 1987).
- **Night use.** A bright screen impairs dark adaptation for what is looked
  at afterwards (Mayr & Buchner 2010).
- **Preference.** It is a legitimate reason; it is not evidence of better
  reading or less fatigue.

## Not supported

- **Halation for astigmatic readers** (light text blooming on dark): only
  blogs claim it; nobody has tested it. The mechanism is plausible, since a
  dark screen widens the pupil.
- **Dark-mode benefits measured in head-mounted displays** (Kim et al.
  2019; Erickson et al. 2020, 2021) do not carry over to desktop monitors.
- **Solarized, Selenized and APCA.** Solarized's and Selenized's lightness
  balancing is sound engineering but untested on readers; APCA, the
  contrast measure proposed for WCAG 3, has no published reading studies.
  WCAG 2's ratio is known to misjudge pairs near black.
- **Code-editor themes over sessions of hours** have never been studied.
  The one code-specific comparison (Nyqvist & Rutqvist 2019, a bachelor
  thesis) found no difference.

## The targets

From the above, for a theme meant for long reading:

| | Light | Dark |
|---|---|---|
| Background | bright, L\* 92–100, low chroma | dark grey, not black: L\* 8–15 |
| Body text | L\* 20 or below; WCAG 12:1+, APCA Lc 90+ | off-white, L\* 80–90; APCA Lc 75–90 |
| Colours read as text | 7:1 preferred, 4.5:1 minimum; desaturated | the same; no saturated blue for thin text |
| Selections | visible as an area (Lc 15+); the text on them at the body's standard | the same |
| Tags | close to the body's luminance, told apart by tint | the same |

Contrast is measured both ways: WCAG 2's ratio, and APCA's Lc, which
handles dark backgrounds better but is itself unvalidated. Never rely on
red against green alone.

## How the themes meet them

| Theme | Element | Colours | L\* text / ground | WCAG 2 | APCA Lc |
|---|---|---|---|---|---|
| glenda | body | `000000` on `FFFFEA` | 0 / 100 | 20.7:1 | 105 |
| glenda | tag | `000000` on `EAFFFF` | 0 / 99 | 20.2:1 | 103 |
| glenda | button 1 selection | `000000` on `EEEE9E` | 0 / 92 | 17.4:1 | 93 |
| glenda | button 2 selection | `FFFFFF` on `AA0000` | 100 / 35 | 7.8:1 | 89 |
| glenda | button 3 selection | `FFFFFF` on `006600` | 100 / 37 | 7.2:1 | 89 |
| xenith | body | `CDD6F4` on `1E1E2E` | 86 / 12 | 11.3:1 | 80 |
| xenith | tag | `CDD6F4` on `313244` | 86 / 21 | 8.7:1 | 76 |
| xenith | button 1 selection | `EFF1F5` on `54566E` | 95 / 37 | 6.3:1 | 80 |
| xenith | button 2 selection | `EFF1F5` on `7C484D` | 95 / 37 | 6.4:1 | 81 |
| xenith | button 3 selection | `EFF1F5` on `3B603D` | 95 / 37 | 6.3:1 | 80 |
| xenith | secondary text | `A6ADC8` on `1E1E2E` | 71 / 12 | 7.4:1 | 56 |
| xenith | accent | `B4BEFE` on `1E1E2E` | 78 / 12 | 9.2:1 | 68 |

Acme's colours, chosen in 1994, already meet the light targets. `xenith`
is Catppuccin Mocha, whose body already met the dark targets, with the
colours that fell short replaced (see the comments in
`lib/lucifer/theme/xenith`). Its selections read 6.3:1 by WCAG 2 and Lc 80
by APCA; on a dark ground the second is the better guide.

Glenda is preferred because the evidence favours a bright screen for
reading. Xenith is for the cases above where dark is justified, and for
those who simply prefer it; the literature cannot show it is better, and on
present evidence nothing could.

## Type

Strongest first.

1. **Size matters most, up to a point.** Reading speed is flat across a
   wide range of sizes and falls steeply below a critical print size
   (Legge et al. 1985a; Legge & Bigelow 2011, who put the fluent range at
   an x-height of 0.2–2° for the population at large). Measured reader by
   reader, the critical size is smaller and grows with age: an x-height of
   about 0.10° from 8 to 23, 0.135° at 68 and 0.18° at 81 (Calabrèse et
   al. 2016, MNREAD: 0.08, 0.21 and 0.34 logMAR). Above it, larger type
   reads no faster; it only puts fewer lines on the screen. The dark-mode
   penalty is concentrated at small sizes (Piepenbrock et al. 2014a), so
   light text on dark wants a margin above the critical size.
2. **Heavier type does not close the dark-mode gap.** Thickening strokes
   had no effect on reading in dark mode (Palmén, Gilbert & Crossland
   2023, n=459); speed falls at both extremes of stroke weight and is flat
   between (Bernard et al. 2013). Size, text luminance and a lit room are
   the levers that work.
3. **Letterforms matter, modestly.** Humanist sans faces beat square
   grotesques by 9–11% in glance legibility (Reimer et al. 2014; Dobres
   et al. 2016). Wider letters and a generous x-height help, until short
   descenders confuse b/p, d/q (Beier & Larson 2010; Larson & Carter 2016,
   2°). Letters are recognised one by one more than words by shape
   (Sheedy et al. 2005), so every glyph must be unambiguous.
4. **Little or no effect:** serif against sans (Arditi & Cho 2005;
   Bernard et al. 2003); subpixel rendering (Gugerty et al. 2004; Sheedy
   et al. 2008); dyslexia fonts (Wery & Diliberto 2017; Kuster et al.
   2018). Slightly loose letter spacing helps a little (Perea & Gomez
   2012); spacing beyond Courier's does not (Chung 2002).
5. **Proportional against monospace for code has never been tested**
   (Oliveira et al. 2021 found no study). For prose, monospace's advantage
   near the size threshold is a spacing effect, and proportional type is
   marginally faster at comfortable sizes (Mansfield, Legge & Bane 1996;
   Xiong et al. 2018). Pike's case for proportional fonts in acme and the
   case that code needs monospace are both folklore.
6. **Readers differ.** Each reader's fastest and slowest fonts differed by
   35% in speed, and no font was best for everyone (Wallace et al. 2022),
   so changing font must stay easy.

### What Xenith does

- **Go and Go Mono** (Bigelow & Holmes 2016): a humanist sans and a
  slab-serif monospace drawn as a pair with the same x-height (0.53 em),
  so `Font` changes face without changing size; open, wide letters; the
  confusable characters drawn apart (DIN 1450). They are freely licensed;
  no published study has evaluated them, and nor has Lucida, Plan 9's
  face by the same designers (Bigelow 2018).
- **Noto Serif** for a serif: its x-height (0.536 em) matches Go's, and its
  letters are wide and low in contrast.
- **14 pixels to the em**, an x-height of about 7.4 px. On a laptop at 2×
  (about 127 logical pixels per inch) at 50 cm that is about 0.17°: 1.7
  times the young reader's critical size and 1.25 times a 68-year-old's,
  the margin for light text on dark. 16 (0.16° at 60 cm) and 18 (0.16° at
  70 cm) are built for monitors further away and for older eyes. A first
  cut used 20, aiming at 0.25° from the population figure; that is above
  even the 81-year-olds' critical size, and read as large print.
- **Regular weight**, since bold does not help in dark mode.
- **Line height 1.25 em.** A convention, not evidence.

## Sources

PR: peer-reviewed. SR: systematic review. NR: narrative review. STD:
standard. GL: grey literature. "2°": known from other papers, not read.

### Contrast, colour and reading

- Legge, Pelli, Rubin, Schleske (1985a). Psychophysics of reading I. Normal vision. *Vision Research* 25:239–252. https://doi.org/10.1016/0042-6989(85)90117-8 [PR]
- Legge, Rubin, Pelli, Schleske (1985b). Psychophysics of reading II. Low vision. *Vision Research* 25:253–265. https://doi.org/10.1016/0042-6989(85)90118-X [PR]
- Legge, Rubin, Luebker (1987). Psychophysics of reading V. The role of contrast in normal vision. *Vision Research* 27:1165–1177. https://doi.org/10.1016/0042-6989(87)90028-9 [PR]
- Legge, Rubin, Schleske (1987). Contrast polarity effects in low vision reading. In *Low Vision*, Springer. https://doi.org/10.1007/978-1-4612-4780-7_24 [PR; 2°]
- Rubin, Legge (1989). Psychophysics of reading VI. The role of contrast in low vision. *Vision Research* 29:79–91. https://doi.org/10.1016/0042-6989(89)90175-2 [PR]
- Legge, Parish, Luebker, Wurm (1990). Psychophysics of reading XI. Comparing color contrast and luminance contrast. *JOSA A* 7:2002–2010. https://doi.org/10.1364/JOSAA.7.002002 [PR]
- Knoblauch, Arditi, Szlyk (1991). Effects of chromatic and luminance contrast on reading. *JOSA A* 8:428–439. https://doi.org/10.1364/JOSAA.8.000428 [PR]
- Whittaker, Lovie-Kitchin (1993). Visual requirements for reading. *Optometry and Vision Science* 70:54–65. https://doi.org/10.1097/00006324-199301000-00010 [PR]
- Penkelink, Besuijen (1996). Chromaticity contrast, luminance contrast, and legibility of text. *J Soc Inf Display* 4:135–144. https://doi.org/10.1889/1.1985002 [PR]
- Pastoor (1990). Legibility and subjective preference for color combinations in text. *Human Factors* 32:157–171. https://doi.org/10.1177/001872089003200204 [PR]
- Wang, Chen (2000). Effects of polarity and luminance contrast on visual performance and VDT display quality. *Int J Industrial Ergonomics* 25:415–421. https://doi.org/10.1016/S0169-8141(99)00040-2 [PR; 2°]
- Shieh, Lin (2000). Effects of screen type, ambient illumination, and color combination on VDT visual performance and subjective preference. *Int J Industrial Ergonomics* 26:527–536. https://doi.org/10.1016/S0169-8141(00)00025-1 [PR; 2°]
- Ling, van Schaik (2002). The effect of text and background colour on visual search of Web pages. *Displays* 23:223–230. https://doi.org/10.1016/S0141-9382(02)00041-0 [PR; 2°]
- Lin (2003). Effects of contrast ratio and text color on visual performance with TFT-LCD. *Int J Industrial Ergonomics* 31:65–72. https://doi.org/10.1016/S0169-8141(02)00175-0 [PR; 2°]
- Lin (2005). Effects of screen luminance combination and text color on visual performance with TFT-LCD. *Int J Industrial Ergonomics* 35:229–235. https://doi.org/10.1016/j.ergon.2004.09.002 [PR; 2°]
- Hall, Hanna (2004). The impact of web page text-background colour combinations on readability, retention, aesthetics and behavioural intention. *Behaviour & IT* 23:183–195. https://doi.org/10.1080/01449290410001669932 [PR]
- Greco, Stucchi, Zavagno, Marino (2008). On the portability of computer-generated presentations: the effect of text-background color combinations on text legibility. *Human Factors* 50:821–833. https://doi.org/10.1518/001872008X354156 [PR]
- Humar, Gradišar, Turk (2008). The impact of color combinations on the legibility of a Web page text presented on CRT displays. *Int J Industrial Ergonomics* 38:885–899. https://doi.org/10.1016/j.ergon.2008.03.004 [PR; 2°]
- Humar, Gradišar, Turk, Erjavec (2014). The impact of color combinations on the legibility of text presented on LCDs. *Applied Ergonomics* 45:1510–1517. https://doi.org/10.1016/j.apergo.2014.04.013 [PR]
- Mullen (1985). The contrast sensitivity of human colour vision to red-green and blue-yellow chromatic gratings. *J Physiology* 359:381–400. https://doi.org/10.1113/jphysiol.1985.sp015591 [PR; 2°]
- Murch (1984). Physiological principles for the effective use of color. *IEEE CG&A* 4(11):48–55. https://doi.org/10.1109/MCG.1984.6429356 [PR; 2°]
- Huang, Wei, Ou (2019). Effect of text-background lightness combination on visual comfort for reading on a tablet display under different surrounds. *Color Research & Application* 44:54–64. https://doi.org/10.1002/col.22259 [PR]
- Li, Liu, Zhu, Luo (2025). Visual comfort models based on coloured text and neutral background combinations. *Vision Research* 227:108524. https://doi.org/10.1016/j.visres.2024.108524 [PR; 2°]
- Na, Suk (2014). Adaptive luminance contrast for enhancing reading performance and visual comfort on smartphone displays. *Optical Engineering* 53:113102. https://doi.org/10.1117/1.OE.53.11.113102 [PR]
- Na, Choi, Suk (2016). Adaptive luminance difference between text and background for comfortable reading on a smartphone. *Int J Industrial Ergonomics* 51:68–72. https://doi.org/10.1016/j.ergon.2015.09.004 [PR]
- Wilkins, Nimmo-Smith (1987). The clarity and comfort of printed text. *Ergonomics* 30:1705–1720. https://doi.org/10.1080/00140138708966059 [PR]
- Wilkins et al. (1984). A neurological basis for visual discomfort. *Brain* 107:989–1017. https://doi.org/10.1093/brain/107.4.989 [PR; 2°]
- Monger, Wilkins, Allen (2015). Pattern glare: the effects of contrast and color. *Frontiers in Psychology* 6:1651. https://doi.org/10.3389/fpsyg.2015.01651 [PR]
- Rello, Bigham (2017). Good background colors for readers: a study of people with and without dyslexia. *ASSETS '17*, 72–80. https://doi.org/10.1145/3132525.3132546 [PR]

### Polarity

- Bauer, Cavonius (1980). Improving the legibility of visual display units through contrast reversal. In Grandjean & Vigliani (eds), *Ergonomic Aspects of Visual Display Terminals*, Taylor & Francis, 137–142. [PR; 2°]
- Radl (1980). Experimental investigations for optimal presentation mode and colours of symbols on the CRT-screen. Same volume, 125–137. [PR; 2°]
- Taptagaporn, Saito (1990). How display polarity and lighting conditions affect the pupil size of VDT operators. *Ergonomics* 33:201–208. https://doi.org/10.1080/00140139008927110 [PR]
- Taptagaporn, Saito (1993). Visual comfort in VDT operation: physiological resting states of the eye. *Industrial Health* 31:13–28. https://doi.org/10.2486/indhealth.31.13 [PR]
- Saito, Taptagaporn, Salvendy (1993). Visual comfort in using different VDT screens. *IJHCI* 5:313–323. https://doi.org/10.1080/10447319309526071 [PR]
- Westheimer, Liang (1995). Influence of ocular light scatter on the eye's optical performance. *JOSA A* 12:1417. https://doi.org/10.1364/JOSAA.12.001417 [PR]
- Westheimer, Chu, Huang, Tran, Dister (2003). Visual acuity with reversed-contrast charts II. Clinical investigation. *Optometry & Vision Science* 80:749–752. https://doi.org/10.1097/00006324-200311000-00011 [PR]
- Chan, Lee (2005). Effect of display factors on Chinese reading times, comprehension scores and preferences. *Behaviour & IT* 24:81–91. https://doi.org/10.1080/0144929042000267073 [PR]
- Buchner, Baumgartner (2007). Text-background polarity affects performance irrespective of ambient illumination and colour contrast. *Ergonomics* 50:1036–1063. https://doi.org/10.1080/00140130701306413 [PR]
- Buchner, Mayr, Brandt (2009). The advantage of positive text-background polarity is due to high display luminance. *Ergonomics* 52:882–886. https://doi.org/10.1080/00140130802641635 [PR]
- Mayr, Buchner (2010). After-effects of TFT-LCD display polarity and display colour on the detection of low-contrast objects. *Ergonomics* 53:914–925. https://doi.org/10.1080/00140139.2010.484508 [PR]
- Lu, Sperling (2012). Black-white asymmetry in visual perception. *Journal of Vision* 12(10):8. https://doi.org/10.1167/12.10.8 [PR]
- Piepenbrock, Mayr, Mund, Buchner (2013). Positive display polarity is advantageous for both younger and older adults. *Ergonomics* 56:1116–1124. https://doi.org/10.1080/00140139.2013.790485 [PR]
- Piepenbrock, Mayr, Buchner (2014a). Positive display polarity is particularly advantageous for small character sizes. *Human Factors* 56:942–951. https://doi.org/10.1177/0018720813515509 [PR]
- Piepenbrock, Mayr, Buchner (2014b). Smaller pupil size and better proofreading performance with positive than with negative polarity displays. *Ergonomics* 57:1670–1677. https://doi.org/10.1080/00140139.2014.948496 [PR]
- Dobres, Chahine, Reimer, Gould, Mehler, Coughlin (2016). Utilising psychophysical techniques to investigate the effects of age, typeface design, size and display polarity on glance legibility. *Ergonomics* 59:1377–1391. https://doi.org/10.1080/00140139.2015.1137637 [PR]
- Dobres, Chahine, Reimer (2017). Effects of ambient illumination, contrast polarity, and letter size on text legibility under glance-like reading. *Applied Ergonomics* 60:68–73. https://doi.org/10.1016/j.apergo.2016.11.001 [PR]
- Aleman, Wang, Schaeffel (2018). Reading and myopia: contrast polarity matters. *Scientific Reports* 8:10840. https://doi.org/10.1038/s41598-018-28904-x [PR]
- Bernal-Molina, Esteve-Taboada, Ferrer-Blasco, Montés-Micó (2019). Influence of contrast polarity on the accommodative response. *J Optometry* 12:38–43. https://doi.org/10.1016/j.optom.2018.03.002 [PR]
- Jiménez, Redondo, Molina, Martínez-Domingo, Hernández-Andrés, Vera (2020). Short-term effects of text-background color combinations on the dynamics of the accommodative response. *Vision Research* 166:33–42. https://doi.org/10.1016/j.visres.2019.11.006 [PR]
- Pedersen, Einarsson, Rikheim, Sandnes (2020). User interfaces in dark mode during daytime: improved productivity or just cool-looking? *UAHCI*, LNCS, 178–187. https://doi.org/10.1007/978-3-030-49282-3_13 [PR]
- Xie, Song, Liu, Wang, Yu (2021). Study on the effects of display color mode and luminance contrast on visual fatigue. *IEEE Access* 9:35915–35923. https://doi.org/10.1109/ACCESS.2021.3061770 [PR]
- Li, Huang, Li, Ma, Zhang, Li (2022). The influence of brightness combinations and background colour on legibility and subjective preference under negative polarity. *Ergonomics* 65:1046–1056. https://doi.org/10.1080/00140139.2021.2013546 [PR]
- Sethi, Ziat (2023). Dark mode vogue: do light-on-dark displays have measurable benefits to users? *Ergonomics* 66:1814–1828. https://doi.org/10.1080/00140139.2022.2160879 [PR]
- Palmén, Gilbert, Crossland (2023). How bold can we be? The impact of adjusting font grade on readability in light and dark polarities. *CHI '23*. https://doi.org/10.1145/3544548.3581552 [PR]
- Wagner, Strasser (2023). Impact of text contrast polarity on the retinal activity in myopes and emmetropes using modified pattern ERG. *Scientific Reports* 13:11101. https://doi.org/10.1038/s41598-023-38192-9 [PR]
- While, Sarvghad (2024). Dark mode or light mode? Exploring the impact of contrast polarity on visualization performance between age groups. *IEEE VIS 2024*, 211–215. https://doi.org/10.1109/VIS55277.2024.00050 [PR]
- Fan, Xie, Dong, Wang (2024). The effect of ambient illumination and text color on visual fatigue under negative polarity. *Sensors* 24:3516. https://doi.org/10.3390/s24113516 [PR]
- Sengsoon, Intaruk (2025). Immediate effects of light mode and dark mode features on visual fatigue in tablet users. *IJERPH* 22:609. https://doi.org/10.3390/ijerph22040609 [PR]
- Ettling, Steinmann, Bektaş, Abbad-Andaloussi (2025). An eye tracking study on the effects of dark and light themes on user performance and workload. *ETRA '25*. https://doi.org/10.1145/3715669.3725879 [PR]
- Cassanello, Roach, Scholes, McGraw (2025). The effect of contrast reversal on peripheral visual acuity. *TVST* 14(8):23. https://doi.org/10.1167/tvst.14.8.23 [PR]
- Gazit, Tager-Shafrir, Zhong, Hung, Cheung (2026). The dark side of the interface: examining the influence of different background modes on cognitive performance. *Ergonomics* 69:828–841. https://doi.org/10.1080/00140139.2025.2483451 [PR]
- Somkijrungroj et al. (2026). Digital visual acuity and reading performance with positive and negative display polarities after bilateral diffractive multifocal IOL implantation. *Clinical Ophthalmology* 20. https://doi.org/10.2147/OPTH.S617151 [PR]
- Muhamad, Amali (2023). Digital display preference of electronic gadgets for visual comfort: a systematic review. *Iranian J Public Health* 52:1565–1577. https://doi.org/10.18502/ijph.v52i8.13396 [SR, lower quality]

Head-mounted displays (not applicable to monitors):

- Kim, Erickson, Lambert, Bruder, Welch (2019). Effects of dark mode on visual fatigue and acuity in optical see-through head-mounted displays. *ACM SUI '19*. https://doi.org/10.1145/3357251.3357584 [PR]
- Erickson, Kim, Bruder, Welch (2020). Effects of dark mode graphics on visual acuity and fatigue with virtual reality head-mounted displays. *IEEE VR 2020*, 434–442. https://doi.org/10.1109/VR46266.2020.1580695145399 [PR]
- Erickson, Kim, Lambert, Bruder, Browne, Welch (2021). An extended analysis on the benefits of dark mode user interfaces in optical see-through head-mounted displays. *ACM TAP* 18:1–22. https://doi.org/10.1145/3456874 [PR]
- Luzsa, Mayr (2026). The polarity effect in virtual and video see-through mixed reality. *Ergonomics* 69:221–235. https://doi.org/10.1080/00140139.2025.2457470 [PR]

### Fatigue, eye strain and blue light

- Rosenfield (2011). Computer vision syndrome: a review of ocular causes and potential treatments. *Ophthalmic Physiol Opt* 31:502–515. https://doi.org/10.1111/j.1475-1313.2011.00834.x [NR]
- Rosenfield (2016). Computer vision syndrome (a.k.a. digital eye strain). *Optometry in Practice* 17:1–10. [NR]
- Sheppard, Wolffsohn (2018). Digital eye strain: prevalence, measurement and amelioration. *BMJ Open Ophthalmology* 3:e000146. https://doi.org/10.1136/bmjophth-2018-000146 [NR]
- Wolffsohn et al. (2023). TFOS Lifestyle: impact of the digital environment on the ocular surface. *Ocular Surface* 28:213–252. https://doi.org/10.1016/j.jtos.2023.04.004 [NR, consensus]
- Gowrisankaran, Sheedy (2015). Computer vision syndrome: a review. *Work* 52. https://doi.org/10.3233/WOR-152162 [NR; 2°]
- Sheedy, Hayes, Engle (2003). Is all asthenopia the same? *Optometry and Vision Science* 80:732–739. [PR]
- Sheedy, Smith, Hayes (2005). Visual effects of the luminance surrounding a computer display. *Ergonomics* 48:1114–1128. https://doi.org/10.1080/00140130500208414 [PR]
- Portello, Rosenfield, Bababekova, Estrada, Leon (2012). Computer-related visual symptoms in office workers. *Ophthalmic Physiol Opt* 32:375–382. https://doi.org/10.1111/j.1475-1313.2012.00925.x [PR]
- Argilés, Cardona, Pérez-Cabré, Rodríguez (2015). Blink rate and incomplete blinks in six different controlled hard-copy and electronic reading conditions. *IOVS* 56:6679–6685. https://doi.org/10.1167/iovs.15-16967 [PR]
- Benedetto, Drai-Zerbib, Pedrotti, Tissier, Baccino (2013). E-readers and visual fatigue. *PLoS ONE* 8:e83676. https://doi.org/10.1371/journal.pone.0083676 [PR]
- Benedetto, Carbone, Drai-Zerbib, Pedrotti, Baccino (2014). Effects of luminance and illuminance on visual fatigue and arousal during digital reading. *Computers in Human Behavior* 41:112–119. https://doi.org/10.1016/j.chb.2014.09.023 [PR]
- van den Berg TJTP et al. (2007). Straylight effects with aging and lens extraction. *Am J Ophthalmol* 144:358–363. https://doi.org/10.1016/j.ajo.2007.05.037 [PR]
- Singh, Downie, Anderson (2021). Do blue-blocking lenses reduce eye strain from extended screen time? A double-masked randomized controlled trial. *Am J Ophthalmol*. https://doi.org/10.1016/j.ajo.2021.02.010 [PR, RCT]
- Singh et al. (2023). Blue-light filtering spectacle lenses for visual performance, sleep, and macular health in adults. *Cochrane Database Syst Rev* CD013244. https://doi.org/10.1002/14651858.CD013244.pub2 [SR]
- Singh, Downie, Anderson (2023). Is critical flicker-fusion frequency a valid measure of visual fatigue? *Ophthalmic Physiol Opt*. https://doi.org/10.1111/opo.13073 [PR]
- Lawrenson, Hull, Downie (2017). The effect of blue-light blocking spectacle lenses on visual performance, macular health and the sleep-wake cycle. *Ophthalmic Physiol Opt* 37:644–654. https://doi.org/10.1111/opo.12406 [SR]
- Lin, Gerratt, Bassi, Apte (2017). Short-wavelength light-blocking eyeglasses attenuate symptoms of eye fatigue. *IOVS*. https://doi.org/10.1167/iovs.16-20663 [PR, RCT]
- Chang, Aeschbach, Duffy, Czeisler (2015). Evening use of light-emitting eReaders negatively affects sleep, circadian timing, and next-morning alertness. *PNAS* 112:1232–1237. https://doi.org/10.1073/pnas.1418490112 [PR]
- Nagare, Plitnick, Figueiro (2019). Does the iPad Night Shift mode reduce melatonin suppression? *Lighting Res Technol* 51:373–383. https://doi.org/10.1177/1477153517748189 [PR]
- Griffiths, Taylor, Henderson, Barrett (2016). The effect of coloured overlays and lenses on reading: a systematic review of the literature. *Ophthalmic Physiol Opt* 36:519–544. https://doi.org/10.1111/opo.12316 [SR]
- Henderson, Taylor, Barrett, Griffiths (2014). Treating reading difficulties with colour. *BMJ* 349:g5160. https://doi.org/10.1136/bmj.g5160 [PR commentary]
- Uccula, Enna, Mulatti (2014). Colors, colored overlays, and reading skills. *Frontiers in Psychology* 5:833. https://doi.org/10.3389/fpsyg.2014.00833 [PR review]
- American Academy of Ophthalmology. Are blue light-blocking glasses worth it? https://www.aao.org/eye-health/tips-prevention/are-computer-glasses-worth-it [GL]

### Code

- Sarkar (2015). The impact of syntax colouring on program comprehension. *PPIG 2015*. https://ppig.org/files/2015-PPIG-26th-Sarkar1.pdf [PR workshop]
- Beelders, du Plessis (2015). Syntax highlighting as an influencing factor when reading and comprehending source code. *J Eye Movement Research* 9(1). https://doi.org/10.16910/jemr.9.1.1 [PR]
- Hannebauer, Hesenius, Gruhn (2018). Does syntax highlighting help programming novices? *Empirical Software Engineering* 23:2795–2828. https://doi.org/10.1007/s10664-017-9579-0 [PR]
- Park, Weill-Tessier, Brown, Sharif, Jensen, Kölling (2023). An eye tracking study assessing the impact of background styling in code editors on novice programmers' code understanding. *ICER '23*. https://doi.org/10.1145/3568813.3600133 [PR]
- Nyqvist, Rutqvist (2019). The impact of colour themes on code readability. Bachelor thesis, KTH. https://www.diva-portal.org/smash/get/diva2:1337805/FULLTEXT01.pdf [GL]

### Standards and contrast measures

- ISO 9241-303:2011. Ergonomics of human-system interaction, Part 303: Requirements for electronic visual displays. [STD; preview only]
- W3C. WCAG 2.2, Understanding SC 1.4.3 Contrast (Minimum). https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html [STD]
- CIE 015:2018 Colorimetry, 4th ed. https://doi.org/10.25039/TR.015.2018 [STD; 2°]
- Somers. APCA documentation. https://git.apcacontrast.com/documentation/APCA_in_a_Nutshell.html [GL]
- W3C wcag3 issue 29, Contrast research: APCA peer reviews. https://github.com/w3c/wcag3/issues/29 [GL]
- xi. The missing introduction to APCA. https://github.com/xi/apca-introduction [GL]
- Waller (2022). Does the contrast ratio actually predict the legibility of website text? Cambridge EDC. https://www.cedc.tools/article.html [GL; 2°]
- Ottosson (2020). A perceptual color space for image processing (OKLab). https://bottosson.github.io/posts/oklab/ [GL]
- Schoonover. Solarized. https://ethanschoonover.com/solarized/ [GL]
- Warchoł. Selenized. https://github.com/jan-warchol/selenized [GL]
- Budiu (2020). Dark mode vs. light mode: which is better? Nielsen Norman Group. https://www.nngroup.com/articles/dark-mode/ [GL]
- Catppuccin. https://catppuccin.com/palette [GL; the source of `xenith`'s palette]

### Type

- Calabrèse, Cheong, Cheung, He, Kwon, Mansfield, Subramanian, Yu, Legge (2016). Baseline MNREAD measures for normally sighted subjects from childhood to old age. *IOVS* 57:3836. https://doi.org/10.1167/iovs.16-19580 [PR; values via the abstract]
- Legge, Bigelow (2011). Does print size matter for reading? A review of findings from vision science and typography. *Journal of Vision* 11(5):8. https://doi.org/10.1167/11.5.8 [PR]
- Pelli et al. (2007). Crowding and eccentricity determine reading rate. *Journal of Vision* 7(2):20. https://doi.org/10.1167/7.2.20 [PR]
- Mansfield, Legge, Bane (1996). Psychophysics of reading XV. Font effects in normal and low vision. *IOVS* 37:1492. PMID 8675391 [PR]
- Arditi, Cho (2005). Serifs and font legibility. *Vision Research* 45:2926. https://doi.org/10.1016/j.visres.2005.06.013 [PR]
- Bernard, Chaparro, Mills, Halcomb (2003). Comparing the effects of text size and format on the readibility of computer-displayed Times New Roman and Arial text. *IJHCS* 59:823. https://doi.org/10.1016/S1071-5819(03)00121-6 [PR; 2°]
- Bernard, Fernandez, Hull, Chaparro (2003). The effects of line length on children and adults' perceived and actual online reading performance. *Proc HFES* 47:1375. https://doi.org/10.1177/154193120304701112 [PR]
- Bernard, Kumar, Junge, Chung (2013). The effect of letter-stroke boldness on reading speed in central and peripheral vision. *Vision Research* 84:33. https://doi.org/10.1016/j.visres.2013.03.005 [PR]
- Boyarski, Neuwirth, Forlizzi, Regli (1998). A study of fonts designed for screen display. *CHI '98*, 87. https://doi.org/10.1145/274644.274658 [PR]
- Sheedy, Subbaram, Zimmerman, Hayes (2005). Text legibility and the letter superiority effect. *Human Factors* 47:797. https://doi.org/10.1518/001872005775570998 [PR]
- Sheedy, Tai, Subbaram, Gowrisankaran, Hayes (2008). ClearType sub-pixel text rendering: preference, legibility and reading performance. *Displays* 29:138. https://doi.org/10.1016/j.displa.2007.09.016 [PR]
- Gugerty, Tyrrell, Aten, Edmonds (2004). The effects of subpixel addressing on users' performance and preferences while reading web-like text. *ACM TAP* 1:81. https://doi.org/10.1145/1024083.1024084 [PR]
- Beier, Larson (2010). Design improvements for frequently misrecognized letters. *Information Design Journal* 18(2). https://doi.org/10.1075/idj.18.2.03bei [PR]
- Beier, Larson (2013). How does typeface familiarity affect reading performance and reader preference? *Information Design Journal* 20:16. https://doi.org/10.1075/idj.20.1.02bei [PR]
- Beier, Oderkerk (2019). The effect of age and font on reading ability. *Visible Language* 53(3). https://doi.org/10.34314/vl.v53i3.4654 [PR]
- Beier et al. (2022). Readability research: an interdisciplinary approach. *Foundations and Trends in HCI* 16:214. https://doi.org/10.1561/1100000089 [NR]
- Larson, Carter (2016). Sitka: a collaboration between type design and science. In Dyson & Suen (eds), *Digital Fonts and Reading*, World Scientific, 37–53. [PR chapter; 2°]
- Minakata, Beier (2021). The effect of font width on eye movements during reading. *Applied Ergonomics* 97:103523. https://doi.org/10.1016/j.apergo.2021.103523 [PR]
- Reimer, Mehler, Dobres, Coughlin et al. (2014). Assessing the impact of typeface design in a text-rich automotive user interface. *Ergonomics* 57:1643. https://doi.org/10.1080/00140139.2014.940000 [PR]
- Dobres, Reimer, Chahine (2016). The effect of font weight and rendering system on glance-based text legibility. *AutomotiveUI '16*, 91. https://doi.org/10.1145/3003715.3005454 [PR]
- Chung (2002). The effect of letter spacing on reading speed in central and peripheral vision. *IOVS* 43:1270. PMID 11923275 [PR]
- Chung (2004). Reading speed benefits from increased vertical word spacing in normal peripheral vision. *Optometry and Vision Science* 81:525. https://doi.org/10.1097/00006324-200407000-00014 [PR; 2°]
- Chung et al. (2008). Line spacing and reading in age-related macular degeneration [title not recorded]. *Optometry and Vision Science* 85:827. https://doi.org/10.1097/OPX.0b013e31818527ea [PR]
- Perea, Moret-Tatay, Gómez (2011). The effects of interletter spacing in visual-word recognition. *Acta Psychologica* 137:345. https://doi.org/10.1016/j.actpsy.2011.04.003 [PR; 2°]
- Perea, Gomez (2012). Increasing interletter spacing facilitates encoding of words. *Psychonomic Bulletin & Review* 19:332. https://doi.org/10.3758/s13423-011-0214-6 [PR]
- Slattery, Rayner (2013). Effects of intraword and interword spacing on eye movements during reading. *Attention, Perception & Psychophysics* 75:1275. https://doi.org/10.3758/s13414-013-0463-8 [PR]
- Zorzi et al. (2012). Extra-large letter spacing improves reading in dyslexia. *PNAS* 109:11455. https://doi.org/10.1073/pnas.1205566109 [PR]
- Sjoblom, Eaton, Stagg (2016). The effects of letter spacing and coloured overlays on reading speed and accuracy in adult dyslexia. *British Journal of Educational Psychology* 86:630. https://doi.org/10.1111/bjep.12127 [PR]
- Dyson (2004). How physical text layout affects reading from screen. *Behaviour & IT* 23:377. https://doi.org/10.1080/01449290410001715714 [NR]
- Dyson, Haselgrove (2001). The influence of reading speed and line length on the effectiveness of reading from screen. *IJHCS* 54:585. https://doi.org/10.1006/ijhc.2001.0458 [PR; 2°]
- Wallace et al. (2022). Towards individuated reading experiences: different fonts increase reading speed for different individuals. *ACM TOCHI* 29:1. https://doi.org/10.1145/3502222 [PR]
- Wery, Diliberto (2017). The effect of a specialized dyslexia font, OpenDyslexic, on reading rate and accuracy. *Annals of Dyslexia* 67:114. https://doi.org/10.1007/s11881-016-0127-1 [PR]
- Kuster, van Weerdenburg, Gompel, Bosman (2018). Dyslexie font does not benefit reading in children with or without dyslexia. *Annals of Dyslexia* 68:25. https://doi.org/10.1007/s11881-017-0154-6 [PR]
- Rello, Baeza-Yates (2013). Good fonts for dyslexia. *ASSETS '13*. https://doi.org/10.1145/2513383.2513447 [PR]
- Rello, Baeza-Yates (2016). The effect of font type on screen readability by people with dyslexia. *ACM TACCESS* 8:1. https://doi.org/10.1145/2897736 [PR]
- Xiong, Lorsung, Mansfield, Bigelow, Legge (2018). Fonts designed for macular degeneration: impact on reading. *IOVS* 59:4182. https://doi.org/10.1167/iovs.18-24334 [PR]
- Legge, Xiong et al. (2026). Assessment of newly designed fonts for visual accessibility. *PLOS One* 21:e0345068. https://doi.org/10.1371/journal.pone.0345068 [PR]
- Richardson (2022). *The Legibility of Serif and Sans Serif Typefaces*. SpringerBriefs. https://doi.org/10.1007/978-3-030-90984-0 [NR; 2°]
- Bigelow (2019). Typeface features and legibility research. *Vision Research* 165:162. https://doi.org/10.1016/j.visres.2019.05.003 [NR]
- Bigelow, Holmes (1986). The design of Lucida: an integrated family of types for electronic literacy. In *Text Processing and Document Manipulation*, Cambridge University Press, 1–17. https://doi.org/10.1017/CBO9780511663130.002 [PR; 2°]
- Bigelow (2018). Science and history behind the design of Lucida. *TUGboat* 39(3):204. https://www.tug.org/TUGboat/tb39-3/tb123bigelow-lucida.pdf [GL]
- Tao, Bigelow, Pike (2016). Go fonts. The Go Blog. https://go.dev/blog/go-fonts [GL]
- Oliveira, Bruno, Madeiral, Castor (2021). Evaluating code readability and legibility: an examination of human-centric studies. arXiv:2110.00785. https://arxiv.org/abs/2110.00785 [SR]
- Binkley, Davis, Lawrie, Morrell (2009). To camelcase or under_score. *ICPC 2009*. https://doi.org/10.1109/ICPC.2009.5090039 [PR; 2°]
- Sharif, Maletic (2010). An eye tracking study on camelCase and under_score identifier styles. *ICPC 2010*. https://doi.org/10.1109/ICPC.2010.41 [PR; 2°]
- Atkinson Hyperlegible: no peer-reviewed evaluation found; claims come from the Braille Institute and its design agency. [GL]

Not verified, cited only inside the papers above: Sloan (1977), Cushman
(1986), Gould et al. (1987), Creed et al. (1988), Papadopoulos & Goudiras
(2005), Hakala et al. (2006), Tsang et al. (2012).
