import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pro.dart';
import 'theme.dart';
import 'widgets.dart';

/// 設定 › 關於與授權：單字表和考古題的來源、授權和隱私說明
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _ceec = ('大考中心網站', 'https://www.ceec.edu.tw');
  static const _sources = [
    ('大考詞彙與分級', '大學入學考試中心《高中英文參考詞彙表》（111 學年度起適用），僅供非營利學習使用。', [_ceec]),
    ('學測英文考古題', '大學入學考試中心公布的 113 到 115 學年度學科能力測驗英文考科試題與參考答案，僅供學習使用。', [_ceec]),
    (
      '國中小 1200',
      '教育部《十二年國民基本教育課程綱要 語文領域－英語文》附錄五表一「基本 1,200 字」。',
      <(String, String)>[],
    ),
    (
      '多益',
      'TOEIC Service List 1.2，作者 Browne, C. 與 Culligan, B.，以 CC BY-SA 4.0 授權。捲字裡由它而來的多益標記同樣以 CC BY-SA 4.0 提供。',
      [
        (
          'TOEIC Service List',
          'https://newgeneralservicelist.com/toeic-service-list',
        ),
        ('CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/'),
      ],
    ),
    (
      '雅思、托福、中文解釋與音標',
      '整理自 ECDICT（作者 skywind3000），MIT 授權，並轉成繁體中文（台灣用語）。內容可能有誤，可以在單字頁自己修改。',
      [('ECDICT', 'https://github.com/skywind3000/ECDICT')],
    ),
    ('圖示', 'Material Icons（Apache 2.0）。', <(String, String)>[]),
  ];

  static Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget link(String label, String url) => Tap(
      onTap: () => _open(url),
      child: Text(
        label,
        style: ts(F.foot, w: w6, c: p.accent),
      ),
    );
    return NavPage(
      title: '關於與授權',
      slivers: [
        Sec(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '大考詞彙、分級和學測考古題永遠免費，不受任何付費限制。捲字 Pro 收的是 App 功能的費用，不是這些內容的費用。',
                style: ts(F.sub, c: p.ink),
              ),
            ),
          ],
        ),
        Sec(
          header: '資料來源與授權',
          children: [
            for (final (title, body, links) in _sources)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ts(F.sub, w: w6, c: p.ink),
                    ),
                    const SizedBox(height: 4),
                    Text(body, style: ts(F.foot, c: p.sec)),
                    if (links.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [for (final (l, u) in links) link(l, u)],
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
        Sec(
          header: '隱私',
          footer: '學習資料預設只存在這台裝置；登入後會同步到雲端，每個人只能讀寫自己的資料。設定自訂 API 後，字典沒有的字會傳到該 API 翻譯。',
          children: [
            RowTile(
              title: '隱私權政策',
              titleColor: p.accent,
              onTap: () => _open(ProStore.privacy.toString()),
            ),
            RowTile(
              title: '服務條款',
              titleColor: p.accent,
              onTap: () => _open(ProStore.terms.toString()),
            ),
            RowTile(
              title: '原始碼（GitHub）',
              titleColor: p.accent,
              onTap: () => _open('https://github.com/HowWeiChi-app/JuanGo'),
            ),
            RowTile(
              title: '開放原始碼套件授權',
              chevron: true,
              onTap: () => pushPage(context, const _Licenses()),
            ),
          ],
        ),
      ],
    );
  }
}

/// App 用到的開放原始碼套件，各自的授權全文
class _Licenses extends StatelessWidget {
  const _Licenses();

  static Future<Map<String, List<String>>> _load() async {
    final out = <String, List<String>>{};
    await for (final l in LicenseRegistry.licenses) {
      final text = l.paragraphs
          .map((p) => '${'  ' * p.indent.clamp(0, 8)}${p.text}')
          .join('\n\n');
      for (final pkg in l.packages) {
        (out[pkg] ??= []).add(text);
      }
    }
    return Map.fromEntries(
      out.entries.toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        final all = snap.data;
        return NavPage(
          title: '套件授權',
          slivers: [
            Sec(
              footer: 'Android 版用 Flutter 和下列套件製作。',
              children: [
                if (all == null)
                  RowTile(title: '讀取中…', titleColor: p.sec)
                else if (all.isEmpty)
                  RowTile(title: '沒有套件授權資料', titleColor: p.sec)
                else
                  for (final e in all.entries)
                    RowTile(
                      title: e.key,
                      value: e.value.length > 1 ? '${e.value.length} 份' : null,
                      chevron: true,
                      onTap: () => pushPage(
                        context,
                        _LicenseText(name: e.key, texts: e.value),
                      ),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LicenseText extends StatelessWidget {
  const _LicenseText({required this.name, required this.texts});
  final String name;
  final List<String> texts;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(
      title: name,
      slivers: [
        for (final t in texts)
          Sec(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(t, style: ts(F.foot, c: p.ink)),
              ),
            ],
          ),
      ],
    );
  }
}
