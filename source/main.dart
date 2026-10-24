// Video Birleştirici v1.1 - sabit resim + ses -> YouTube uyumlu mp4
// ffmpeg.py (Termux) betiğinin APK hali.
// Özellikler:
//  - Seçilen saniye aralıklarında müziği azaltma ya da sesi kapatma
//  - YENİ: Ana sesi dinleyip kesme (başlangıç / bitiş)
//  - YENİ: Üstüne istediğin kadar ses bindirme (InShot gibi):
//          her sesi dinle, kes, videoda istediğin saniyede başlat, ses seviyesini ayarla

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------------- AYARLAR (ffmpeg.py ile aynı) ----------------
final Directory klasor = Directory('/sdcard/ffmpeg');
const sesUzantilar = ['.mp3', '.m4a', '.wav', '.aac', '.ogg', '.opus', '.flac'];
const resimUzantilar = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
const kopyalanabilir = ['.mp3', '.m4a', '.aac'];
const preset = 'ultrafast';
// ---------------------------------------------------------------

enum Mode { muzikKaldir, sesiKapat }

// Çıktı ayarları
class Opts {
  int fps = 1; // saniyedeki kare sayısı (sabit resim için 1 yeterli)
  int crf = 30; // video kalitesi: küçük sayı = daha iyi ve daha büyük
  String res = '1280:720'; // video boyutu
  int audioKbps = 0; // 0 = otomatik (kaynak sese yakın)
}

class Pair {
  final String name;
  final File audio;
  final File? image; // resim yoksa sadece ses kaydedilebilir
  Pair(this.name, this.audio, this.image);

  String get ext {
    final p = audio.path;
    return p.substring(p.lastIndexOf('.')).toLowerCase();
  }

  File get output => File('${klasor.path}/$name.mp4');
  File audioOut(String ext) => File('${klasor.path}/${name}_ses$ext');
}

// Müziği kaldırma / susturma aralığı
class Seg {
  final Key key = UniqueKey();
  int start;
  int end;
  Seg(this.start, this.end);
}

// Üste bindirilen ses
class Layer {
  final Key key = UniqueKey();
  final String path;
  final String name;
  final double duration; // dosyanın tam süresi (sn)
  double trimStart = 0; // dosyadan kesilen parçanın başı (sn)
  double trimEnd; // dosyadan kesilen parçanın sonu (sn)
  int placeAt = 0; // videonun kaçıncı saniyesinde başlasın
  double volume = 1.0; // 1.0 = %100
  Layer(this.path, this.name, this.duration) : trimEnd = duration;
}

String sureYaz(num sn) {
  final s = sn.toInt();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = s % 60;
  String two(int x) => x.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '${two(m)}:${two(r)}';
}

class Engine {
  static List<Pair> tara() {
    final audios = <String, File>{};
    final images = <String, File>{};
    if (!klasor.existsSync()) return [];
    final list = klasor.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final e in list) {
      if (e is! File) continue;
      final base = e.path.split('/').last;
      final dot = base.lastIndexOf('.');
      if (dot <= 0) continue; // gizli dosyalar ve uzantısızlar
      final name = base.substring(0, dot);
      final ext = base.substring(dot).toLowerCase();
      if (name.endsWith('_ses')) continue; // kendi çıktılarımız
      if (sesUzantilar.contains(ext)) audios[name] = e;
      if (resimUzantilar.contains(ext)) images[name] = e;
    }
    final adlar = audios.keys.toList()..sort();
    return [for (final n in adlar) Pair(n, audios[n]!, images[n])];
  }

  static Future<double> sure(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final d = s.getMediaInformation()?.getDuration();
      return double.tryParse(d ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // Konuşma ayıklama modeli (RNNoise). Yoksa sadece filtreler çalışır.
  static Future<String?> modelYolu() async {
    try {
      final data = await rootBundle.load('assets/model.rnnn');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/model.rnnn');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  static String _n(double x) => x.toStringAsFixed(3);

  static Future<int> kaynakKbps(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final b = int.tryParse(s.getMediaInformation()?.getBitrate() ?? '') ?? 0;
      return b ~/ 1000;
    } catch (_) {
      return 0;
    }
  }

  /// Başarılıysa null, hata varsa hata metni döner.
  ///  opts      : kare sayısı, kalite, boyut, ses kalitesi
  ///  sadeceSes : true ise video yapmaz, sadece ses dosyası (m4a) kaydeder
  ///  anaSure   : ana ses dosyasının tam süresi (bilinmiyorsa 0)
  ///  mainStart / mainEnd : ana sesten tutulacak parça (mainEnd 0 ise sona kadar)
  ///  layers    : üste bindirilecek sesler
  ///  toplam    : çıkacak dosyanın süresi (sadece ilerleme çubuğu için)
  static Future<String?> uret(
    Pair p,
    List<Seg> segs,
    Mode mode,
    double toplam,
    void Function(double) ilerleme, {
    Opts? opts,
    bool sadeceSes = false,
    double anaSure = 0,
    double mainStart = 0,
    double mainEnd = 0,
    List<Layer> layers = const [],
  }) async {
    final o = opts ?? Opts();
    final ses = sadeceSes || p.image == null;
    final a0 = ses ? 0 : 1; // ana sesin girdi numarası

    final gecerli = segs.where((s) => s.end > s.start).toList();
    final kesik = anaSure > 0 &&
        (mainStart > 0.05 || (mainEnd > 0 && mainEnd < anaSure - 0.05));
    final duzenleme = kesik || gecerli.isNotEmpty || layers.isNotEmpty;
    // Sadece kesme (ya da hiç düzenleme yok) ve video: ses yeniden kodlanmaz.
    // Böylece hızlı olur ve ses dosyası büyümez.
    final kopya = !ses &&
        kopyalanabilir.contains(p.ext) &&
        gecerli.isEmpty &&
        layers.isEmpty;

    var kbps = o.audioKbps;
    if (kbps <= 0) {
      final k = await kaynakKbps(p.audio.path);
      kbps = k > 0 ? k.clamp(48, 192).toInt() : 96;
    }

    final args = <String>['-y'];
    if (!ses) {
      args.addAll(['-loop', '1', '-framerate', '${o.fps}', '-i', p.image!.path]);
    }
    if (kopya && kesik) {
      args.addAll(['-ss', _n(mainStart)]);
      if (mainEnd > mainStart) args.addAll(['-t', _n(mainEnd - mainStart)]);
    }
    args.addAll(['-i', p.audio.path]);
    for (final l in layers) {
      args.addAll(['-i', l.path]);
    }

    if (!ses) {
      args.addAll([
        '-vf',
        'scale=${o.res}:force_original_aspect_ratio=decrease,'
            'pad=${o.res}:(ow-iw)/2:(oh-ih)/2',
        '-c:v', 'libx264',
        '-tune', 'stillimage',
        '-preset', preset,
        '-crf', '${o.crf}',
        '-pix_fmt', 'yuv420p',
        '-r', '${o.fps}',
        '-g', '${o.fps * 10}',
      ]);
    } else {
      args.add('-vn');
    }

    if (kopya) {
      args.addAll(['-c:a', 'copy']);
    } else if (!duzenleme) {
      args.addAll(['-c:a', 'aac', '-b:a', '${kbps}k']);
    } else {
      final f = <String>[];
      const fmt = 'aformat=sample_rates=44100';

      // 1) Ana sesi kes
      final bitis = mainEnd > mainStart ? ':end=${_n(mainEnd)}' : '';
      f.add('[$a0:a]atrim=start=${_n(mainStart)}$bitis,'
          'asetpts=PTS-STARTPTS,$fmt[m0]');

      // 2) Müzik kaldır / sustur (süreler, kesilmiş sese göre)
      if (gecerli.isEmpty) {
        f.add('[m0]anull[m]');
      } else {
        final expr =
            gecerli.map((s) => 'between(t,${s.start},${s.end})').join('+');
        if (mode == Mode.sesiKapat) {
          f.add("[m0]volume=0:enable='$expr'[m]");
        } else {
          final model = await modelYolu();
          final zincir = [
            'highpass=f=120',
            'lowpass=f=5000',
            if (model != null) 'arnndn=m=$model',
          ].join(',');
          f.add('[m0]asplit=2[o][p]');
          f.add('[p]$zincir[pf]');
          f.add("[o]volume=0:enable='$expr'[oo]");
          f.add("[pf]volume=0:enable='eq($expr,0)'[pp]");
          f.add('[oo][pp]amix=inputs=2:normalize=0:duration=longest[m]');
        }
      }

      // 3) Eklenen sesler
      final etiket = <String>['[m]'];
      for (var i = 0; i < layers.length; i++) {
        final l = layers[i];
        final ms = l.placeAt * 1000;
        f.add('[${a0 + 1 + i}:a]atrim=start=${_n(l.trimStart)}:end=${_n(l.trimEnd)},'
            'asetpts=PTS-STARTPTS,$fmt,'
            'volume=${l.volume.toStringAsFixed(2)},'
            'adelay=$ms:all=1[l$i]');
        etiket.add('[l$i]');
      }

      // 4) Hepsini karıştır
      if (etiket.length == 1) {
        f.add('[m]anull[a]');
      } else {
        f.add('${etiket.join()}amix=inputs=${etiket.length}:normalize=0:'
            'duration=longest,alimiter=limit=0.95[a]');
      }

      args.addAll(['-filter_complex', f.join(';')]);
      if (!ses) args.addAll(['-map', '0:v']);
      args.addAll(['-map', '[a]', '-c:a', 'aac', '-b:a', '${kbps}k']);
    }

    if (!ses) args.add('-shortest');
    args.addAll(['-movflags', '+faststart']);
    args.add(ses ? p.audioOut('.m4a').path : p.output.path);

    final c = Completer<String?>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          c.complete(null);
        } else {
          final logs = (await session.getLogsAsString()) ?? '';
          final son = logs.length > 700 ? logs.substring(logs.length - 700) : logs;
          c.complete('FFmpeg hatası:\n$son');
        }
      },
      null,
      (stat) {
        if (toplam > 0) {
          final ms = stat.getTime();
          ilerleme((ms / 1000 / toplam).clamp(0.0, 1.0).toDouble());
        }
      },
    );
    return c.future;
  }
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Video Birleştirici',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const HomePage(),
      );
}

// ======================= ANA SAYFA =======================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool izinVar = false;
  bool calisiyor = false;
  List<Pair> pairs = [];
  String durum = '';
  double ilerleme = 0;

  @override
  void initState() {
    super.initState();
    yukle();
  }

  Future<bool> izinIste() async {
    if (await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted) {
      return true;
    }
    if ((await Permission.storage.request()).isGranted) return true;
    return (await Permission.manageExternalStorage.request()).isGranted;
  }

  Future<void> yukle() async {
    final ok = await izinIste();
    if (ok && !klasor.existsSync()) {
      try {
        klasor.createSync(recursive: true);
      } catch (_) {}
    }
    setState(() {
      izinVar = ok;
      pairs = ok ? Engine.tara() : [];
    });
  }

  Future<void> hepsiniBirlestir() async {
    setState(() {
      calisiyor = true;
      ilerleme = 0;
    });
    await WakelockPlus.enable();
    int ok = 0, atlanan = 0, hata = 0;
    for (var i = 0; i < pairs.length; i++) {
      final p = pairs[i];
      if (p.image == null || p.output.existsSync()) {
        atlanan++;
        continue;
      }
      setState(() => durum = '[${i + 1}/${pairs.length}] ${p.name}');
      final toplam = await Engine.sure(p.audio.path);
      final err = await Engine.uret(p, [], Mode.muzikKaldir, toplam,
          (x) => setState(() => ilerleme = x));
      if (err == null) {
        ok++;
      } else {
        hata++;
      }
    }
    await WakelockPlus.disable();
    setState(() {
      calisiyor = false;
      ilerleme = 0;
      durum = '$ok başarılı | $atlanan atlandı | $hata hatalı';
    });
    yukle();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Birleştirici'),
        actions: [
          IconButton(onPressed: calisiyor ? null : yukle, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: !izinVar
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                    '/sdcard/ffmpeg klasörünü okuyabilmem için "tüm dosyalara erişim" iznini vermelisin.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: yukle, child: const Text('İzin ver / yeniden dene')),
                  TextButton(onPressed: openAppSettings, child: const Text('Uygulama ayarlarını aç')),
                ]),
              ),
            )
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Klasör: ${klasor.path}\nSes dosyası: ${pairs.length}\n'
                  'Aynı isimli resim eşleşir (örn. tiyatro.mp3 + tiyatro.jpg). '
                  'Resmi olmayan sesler sadece ses olarak kaydedilir.',
                ),
              ),
              if (calisiyor) LinearProgressIndicator(value: ilerleme),
              if (durum.isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(durum)),
              Expanded(
                child: ListView.builder(
                  itemCount: pairs.length,
                  itemBuilder: (_, i) {
                    final p = pairs[i];
                    return ListTile(
                      leading: p.image == null
                          ? const SizedBox(width: 56, height: 56, child: Icon(Icons.audiotrack))
                          : Image.file(p.image!, width: 56, height: 56, fit: BoxFit.cover,
                          cacheWidth: 112,
                          errorBuilder: (_, __, ___) => const Icon(Icons.image)),
                      title: Text(p.name),
                      subtitle: Text(p.image == null
                          ? 'resim yok (sadece ses)'
                          : p.output.existsSync() ? 'mp4 hazır ✅' : p.audio.path.split('/').last),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: calisiyor
                          ? null
                          : () async {
                              await Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => EditorPage(pair: p)));
                              yukle();
                            },
                    );
                  },
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (calisiyor || pairs.isEmpty) ? null : hepsiniBirlestir,
                      icon: const Icon(Icons.movie),
                      label: const Text('Hepsini birleştir (düzenlemesiz, var olanı atla)'),
                    ),
                  ),
                ),
              ),
            ]),
    );
  }
}

// ======================= DÜZENLEME SAYFASI =======================
class EditorPage extends StatefulWidget {
  final Pair pair;
  const EditorPage({super.key, required this.pair});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final List<Seg> segs = [];
  final List<Layer> layers = [];
  Mode mode = Mode.muzikKaldir;
  final Opts opts = Opts();
  bool sadeceSes = false;
  bool get sesMod => sadeceSes || widget.pair.image == null;
  double toplam = 0; // ana sesin tam süresi
  double mainStart = 0; // ana sesten tutulacak parça
  double mainEnd = 0;
  double ilerleme = 0;
  bool calisiyor = false;
  String durum = '';

  @override
  void initState() {
    super.initState();
    Engine.sure(widget.pair.audio.path).then((d) {
      if (!mounted) return;
      setState(() {
        toplam = d;
        mainEnd = d;
      });
    });
  }

  Future<void> sesEkle() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) {
      final path = f.path;
      if (path == null) continue;
      final d = await Engine.sure(path);
      if (!mounted) return;
      if (d <= 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Okunamadı: ${f.name}')));
        continue;
      }
      setState(() => layers.add(Layer(path, f.name, d)));
    }
  }

  Future<void> olustur() async {
    final anaUzun = mainEnd - mainStart;
    if (anaUzun < 0.1) {
      setState(() => durum = 'Ana ses aralığı geçersiz (bitiş, başlangıçtan büyük olmalı).');
      return;
    }
    final gecerliKatman = layers.where((l) => l.trimEnd - l.trimStart > 0.05).toList();
    double video = anaUzun;
    for (final l in gecerliKatman) {
      video = math.max(video, l.placeAt + (l.trimEnd - l.trimStart));
    }

    setState(() {
      calisiyor = true;
      ilerleme = 0;
      durum = 'Çalışıyor... Uygulamayı kapatma.';
    });
    await WakelockPlus.enable();
    final err = await Engine.uret(
      widget.pair,
      segs,
      mode,
      video,
      (x) => setState(() => ilerleme = x),
      opts: opts,
      sadeceSes: sesMod,
      anaSure: toplam,
      mainStart: mainStart,
      mainEnd: mainEnd,
      layers: gecerliKatman,
    );
    await WakelockPlus.disable();
    setState(() {
      calisiyor = false;
      durum = err ??
          '✅ Bitti: ${sesMod ? widget.pair.audioOut('.m4a').path : widget.pair.output.path}';
      if (err == null) ilerleme = 1;
    });
  }

  Widget ayar(String ad, Widget w) =>
      Row(children: [Expanded(child: Text(ad)), w]);

  @override
  Widget build(BuildContext context) {
    final p = widget.pair;
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: p.image == null
              ? const SizedBox(
                  height: 80,
                  child: Center(child: Text('Resim yok: sadece ses kaydedilebilir')))
              : Image.file(p.image!, height: 160, fit: BoxFit.cover, cacheWidth: 600),
        ),
        const SizedBox(height: 8),
        Text('Ses süresi: ${toplam > 0 ? sureYaz(toplam) : '...'}'),

        // ---------- 1) ANA SESİ KES ----------
        const Divider(height: 24),
        const Text('1) Ana ses: dinle ve kes',
            style: TextStyle(fontWeight: FontWeight.bold)),
        if (toplam > 0)
          SoundTrimmer(
            key: const ValueKey('ana'),
            path: p.audio.path,
            duration: toplam,
            start: mainStart,
            end: mainEnd,
            onChanged: (s, e) {
              mainStart = s;
              mainEnd = e;
            },
          )
        else
          const Padding(padding: EdgeInsets.all(8), child: Text('Ses okunuyor...')),

        // ---------- 2) ÜSTE SES EKLE ----------
        const Divider(height: 24),
        const Text('2) Üste ses ekle',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const Text('Her sesi dinleyip kesebilir, videoda istediğin saniyede başlatabilirsin.'),
        for (final l in layers)
          Card(
            key: l.key,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(l.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: calisiyor ? null : () => setState(() => layers.remove(l)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ]),
                SoundTrimmer(
                  path: l.path,
                  duration: l.duration,
                  start: l.trimStart,
                  end: l.trimEnd,
                  onChanged: (s, e) {
                    l.trimStart = s;
                    l.trimEnd = e;
                  },
                ),
                const Divider(),
                TimeBox(
                  label: 'Videonun kaçıncı saniyesinde başlasın',
                  value: l.placeAt,
                  onChanged: (v) => l.placeAt = v,
                ),
                Row(children: [
                  const Text('Ses seviyesi'),
                  Expanded(
                    child: Slider(
                      value: l.volume,
                      min: 0,
                      max: 2,
                      divisions: 20,
                      label: '%${(l.volume * 100).round()}',
                      onChanged: (v) => setState(() => l.volume = v),
                    ),
                  ),
                  Text('%${(l.volume * 100).round()}'),
                ]),
              ]),
            ),
          ),
        OutlinedButton.icon(
          onPressed: calisiyor ? null : sesEkle,
          icon: const Icon(Icons.library_music),
          label: const Text('Ses ekle'),
        ),

        // ---------- 3) MÜZİK KALDIR ----------
        const Divider(height: 24),
        const Text('3) Seçtiğin aralıklarda ne yapılsın?',
            style: TextStyle(fontWeight: FontWeight.bold)),
        RadioListTile<Mode>(
          value: Mode.muzikKaldir,
          groupValue: mode,
          onChanged: calisiyor ? null : (v) => setState(() => mode = v!),
          title: const Text('Gürültüyü/müziği azalt'),
          subtitle: const Text('Tam silmez; azalır ama kalabilir.'),
        ),
        RadioListTile<Mode>(
          value: Mode.sesiKapat,
          groupValue: mode,
          onChanged: calisiyor ? null : (v) => setState(() => mode = v!),
          title: const Text('Ana sesi tamamen kapat'),
          subtitle: const Text('Aralıkta ana ses duyulmaz. Eklediğin sesler etkilenmez.'),
        ),
        const Text('Aralıklar (saat : dakika : saniye)\n'
            'Süreler, kesmeden sonraki sese göredir.',
            style: TextStyle(fontWeight: FontWeight.bold)),
        for (final s in segs)
          Card(
            key: s.key,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Expanded(child: TimeBox(label: 'Başlangıç', value: s.start, onChanged: (v) => s.start = v)),
                const SizedBox(width: 8),
                Expanded(child: TimeBox(label: 'Bitiş', value: s.end, onChanged: (v) => s.end = v)),
                IconButton(
                  onPressed: calisiyor ? null : () => setState(() => segs.remove(s)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ]),
            ),
          ),
        OutlinedButton.icon(
          onPressed: calisiyor
              ? null
              : () => setState(() {
                    final basla = segs.isEmpty ? 0 : segs.last.end;
                    segs.add(Seg(basla, basla + 10));
                  }),
          icon: const Icon(Icons.add),
          label: const Text('Aralık ekle'),
        ),
        // ---------- 4) ÇIKTI AYARLARI ----------
        const Divider(height: 24),
        const Text('4) Çıktı ayarları', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
                value: false,
                label: const Text('Video'),
                icon: const Icon(Icons.movie),
                enabled: p.image != null),
            const ButtonSegment(
                value: true, label: Text('Sadece ses'), icon: Icon(Icons.audiotrack)),
          ],
          selected: {sesMod},
          onSelectionChanged: calisiyor ? null : (v) => setState(() => sadeceSes = v.first),
        ),
        if (!sesMod) ...[
          ayar(
            'Kare sayısı (saniyede)',
            DropdownButton<int>(
              value: opts.fps,
              items: [1, 2, 5, 10, 24, 30]
                  .map((x) => DropdownMenuItem(value: x, child: Text('$x')))
                  .toList(),
              onChanged: calisiyor ? null : (v) => setState(() => opts.fps = v!),
            ),
          ),
          ayar(
            'Video kalitesi',
            DropdownButton<int>(
              value: opts.crf,
              items: const [
                DropdownMenuItem(value: 35, child: Text('Düşük (küçük dosya)')),
                DropdownMenuItem(value: 30, child: Text('Orta')),
                DropdownMenuItem(value: 24, child: Text('Yüksek')),
                DropdownMenuItem(value: 20, child: Text('Çok yüksek')),
              ],
              onChanged: calisiyor ? null : (v) => setState(() => opts.crf = v!),
            ),
          ),
          ayar(
            'Video boyutu',
            DropdownButton<String>(
              value: opts.res,
              items: const [
                DropdownMenuItem(value: '854:480', child: Text('480p')),
                DropdownMenuItem(value: '1280:720', child: Text('720p')),
                DropdownMenuItem(value: '1920:1080', child: Text('1080p')),
              ],
              onChanged: calisiyor ? null : (v) => setState(() => opts.res = v!),
            ),
          ),
          const Text('Sabit resim için 1 kare yeterlidir: en hızlı ve en küçük dosya budur.',
              style: TextStyle(fontSize: 12)),
        ],
        ayar(
          'Ses kalitesi',
          DropdownButton<int>(
            value: opts.audioKbps,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Otomatik (kaynağa yakın)')),
              DropdownMenuItem(value: 48, child: Text('48 kbps')),
              DropdownMenuItem(value: 64, child: Text('64 kbps')),
              DropdownMenuItem(value: 96, child: Text('96 kbps')),
              DropdownMenuItem(value: 128, child: Text('128 kbps')),
              DropdownMenuItem(value: 192, child: Text('192 kbps')),
            ],
            onChanged: calisiyor ? null : (v) => setState(() => opts.audioKbps = v!),
          ),
        ),
        const SizedBox(height: 16),
        if (calisiyor || ilerleme > 0) LinearProgressIndicator(value: ilerleme),
        if (durum.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(durum)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: (calisiyor || toplam <= 0) ? null : olustur,
          icon: Icon(sesMod ? Icons.audiotrack : Icons.movie_creation),
          label: Text(sesMod ? 'Sesi kaydet' : 'Videoyu oluştur'),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

// ======================= SES DİNLE + KES =======================
// Bir ses dosyasını dinletir; başlangıç ve bitiş seçtirir.
// Kesme yolları: kaydırıcı, "şimdi" düğmeleri ya da elle saat:dk:sn yazma.
class SoundTrimmer extends StatefulWidget {
  final String path;
  final double duration;
  final double start;
  final double end;
  final void Function(double start, double end) onChanged;
  const SoundTrimmer({
    super.key,
    required this.path,
    required this.duration,
    required this.start,
    required this.end,
    required this.onChanged,
  });

  @override
  State<SoundTrimmer> createState() => _SoundTrimmerState();
}

class _SoundTrimmerState extends State<SoundTrimmer> {
  final AudioPlayer player = AudioPlayer();
  late double s = widget.start;
  late double e = widget.end;
  double pos = 0;
  bool caliyor = false;
  bool aralikModu = false; // true: sadece seçili aralığı çal
  int ver = 0; // kutuları yenilemek için sayaç
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _doneSub;

  @override
  void initState() {
    super.initState();
    _posSub = player.onPositionChanged.listen((d) {
      if (!mounted) return;
      final t = d.inMilliseconds / 1000.0;
      if (aralikModu && t >= e) {
        player.pause();
        setState(() {
          caliyor = false;
          pos = e;
        });
      } else {
        setState(() => pos = t.clamp(0.0, widget.duration).toDouble());
      }
    });
    _doneSub = player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => caliyor = false);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _doneSub?.cancel();
    player.dispose();
    super.dispose();
  }

  Future<void> durdur() async {
    await player.pause();
    if (mounted) setState(() => caliyor = false);
  }

  Future<void> cal({required bool aralik}) async {
    aralikModu = aralik;
    double from = pos;
    if (aralik && (pos < s || pos >= e - 0.2)) from = s;
    if (!aralik && pos >= widget.duration - 0.2) from = 0;
    await player.play(
      DeviceFileSource(widget.path),
      position: Duration(milliseconds: (from * 1000).round()),
    );
    if (mounted) setState(() => caliyor = true);
  }

  void degis(double ns, double ne, {bool yenile = true}) {
    ns = ns.clamp(0.0, widget.duration).toDouble();
    ne = ne.clamp(0.0, widget.duration).toDouble();
    if (ne < ns) ne = ns;
    setState(() {
      s = ns;
      e = ne;
      if (yenile) ver++;
    });
    widget.onChanged(s, e);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.duration;
    if (d <= 0) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Konum: ${sureYaz(pos)} / ${sureYaz(d)}'),
      Slider(
        value: pos.clamp(0.0, d).toDouble(),
        min: 0,
        max: d,
        onChanged: (v) => setState(() => pos = v),
        onChangeEnd: (v) async {
          if (caliyor) await player.seek(Duration(milliseconds: (v * 1000).round()));
        },
      ),
      Row(children: [
        if (caliyor)
          Expanded(
            child: FilledButton.icon(
              onPressed: durdur,
              icon: const Icon(Icons.pause),
              label: const Text('Durdur'),
            ),
          )
        else ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => cal(aralik: false),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Dinle'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => cal(aralik: true),
              icon: const Icon(Icons.content_cut),
              label: const Text('Kesilen parçayı dinle'),
            ),
          ),
        ],
      ]),
      Row(children: [
        Expanded(
          child: TextButton(
            onPressed: () => degis(pos, math.max(e, pos)),
            child: const Text('Başlangıç = şimdi'),
          ),
        ),
        Expanded(
          child: TextButton(
            onPressed: () => degis(math.min(s, pos), pos),
            child: const Text('Bitiş = şimdi'),
          ),
        ),
      ]),
      Text('Tutulacak parça: ${sureYaz(s)} → ${sureYaz(e)}  (süre ${sureYaz(e - s)})'),
      RangeSlider(
        values: RangeValues(s, e),
        min: 0,
        max: d,
        onChanged: (v) {
          if (caliyor) durdur();
          degis(v.start, v.end);
        },
      ),
      Row(children: [
        Expanded(
          child: TimeBox(
            key: ValueKey('s$ver'),
            label: 'Başlangıç',
            value: s.round(),
            onChanged: (v) => degis(v.toDouble(), e, yenile: false),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TimeBox(
            key: ValueKey('e$ver'),
            label: 'Bitiş',
            value: e.round(),
            onChanged: (v) => degis(s, v.toDouble(), yenile: false),
          ),
        ),
      ]),
    ]);
  }
}

// Saat : dakika : saniye kutusu
class TimeBox extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const TimeBox({super.key, required this.label, required this.value, required this.onChanged});
  @override
  State<TimeBox> createState() => _TimeBoxState();
}

class _TimeBoxState extends State<TimeBox> {
  late final TextEditingController h, m, s;

  @override
  void initState() {
    super.initState();
    h = TextEditingController(text: '${widget.value ~/ 3600}');
    m = TextEditingController(text: '${(widget.value % 3600) ~/ 60}');
    s = TextEditingController(text: '${widget.value % 60}');
  }

  @override
  void dispose() {
    h.dispose();
    m.dispose();
    s.dispose();
    super.dispose();
  }

  void degisti() {
    final v = (int.tryParse(h.text) ?? 0) * 3600 +
        (int.tryParse(m.text) ?? 0) * 60 +
        (int.tryParse(s.text) ?? 0);
    widget.onChanged(v);
  }

  Widget alan(TextEditingController c, String ipucu) => Expanded(
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            hintText: ipucu,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => degisti(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.label, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 4),
      Row(children: [
        alan(h, 'sa'),
        const SizedBox(width: 3),
        alan(m, 'dk'),
        const SizedBox(width: 3),
        alan(s, 'sn'),
      ]),
    ]);
  }
}
