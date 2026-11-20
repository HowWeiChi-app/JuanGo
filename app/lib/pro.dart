// 捲字 Pro 和 GOs PRO：方案、目前狀態、付費牆和「設定 › 捲字 Pro」。排版照 iOS 版 Pro.swift。
// 之後用 RevenueCat 購買（entitlement `juango_pro`，由 juango_pro_* 和 gos_pro_* 解鎖）；
// 商店還沒開通前，購買和恢復購買都會說明還不能用。

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';
import 'widgets.dart';

/// 開發版（本機 battle 分支）直接當成 GOs PRO，所有付費功能都打開。main 一定是 false
const devGosPro = false;

/// 捲字 Pro 只解鎖捲字；GOs PRO 解鎖 HowWeiChi 所有 App，包括之後推出的
enum ProPlan {
  juango('捲字 Pro', '只有捲字', 'juango'),
  gos('GOs PRO', '捲字、校板和未來所有 App', 'gos');

  const ProPlan(this.label, this.blurb, this._id);
  final String label, blurb, _id;

  int price(ProPeriod p) => switch ((this, p)) {
        (ProPlan.juango, ProPeriod.monthly) => 60,
        (ProPlan.juango, ProPeriod.yearly) => 600,
        (ProPlan.gos, ProPeriod.monthly) => 80,
        (ProPlan.gos, ProPeriod.yearly) => 800,
      };

  /// 商店的商品 ID（App Store 和 Google Play 相同）
  String productId(ProPeriod p) => '${_id}_pro_${p.name}';
}

enum ProPeriod {
  monthly('月'),
  yearly('年');

  const ProPeriod(this.unit);
  final String unit;
}

class ProStore extends ChangeNotifier {
  ProStore._() {
    if (devGosPro) {
      plan = ProPlan.gos;
      devUnlocked = true;
    }
  }
  static final shared = ProStore._();

  ProPlan? plan;
  ProPeriod? period;
  DateTime? expires;

  /// 開發版解鎖，不是買的
  bool devUnlocked = false;

  bool get isPro => plan != null;

  static const notOpen = '商店還沒開通，App 上架後就能訂閱。';

  Future<void> purchase(ProPlan plan, ProPeriod period) async => throw notOpen;
  Future<void> restore() async => throw notOpen;

  static final terms = Uri.parse('https://howweichi-app.github.io/terms/');
  static final privacy = Uri.parse('https://howweichi-app.github.io/privacy/');
  static final manage = Uri.parse('https://play.google.com/store/account/subscriptions?package=io.github.howweichi.juango');
  static final redeem = Uri.parse('https://play.google.com/redeem');
}

Future<void> _open(Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);

// MARK: 付費牆

class ProPaywall extends StatefulWidget {
  const ProPaywall({super.key});
  @override
  State<ProPaywall> createState() => _ProPaywallState();
}

class _ProPaywallState extends State<ProPaywall> {
  ProPlan _plan = ProPlan.gos;
  ProPeriod _period = ProPeriod.yearly;
  bool _busy = false;
  ProStore get _pro => ProStore.shared;

  /// 買了的方案；開發版的解鎖不算，付費牆才能完整展示
  ProPlan? get _held => _pro.devUnlocked ? null : _pro.plan;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) await showAlert(context, '無法完成', message: '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final owned = _held == ProPlan.gos;
    final upgrade = _held == ProPlan.juango;
    final price = _plan.price(_period);
    return NavPage(
      close: true,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            child: Column(children: [
              Icon(Icons.auto_awesome_rounded, size: 44, color: p.accent),
              const SizedBox(height: 8),
              Text(upgrade ? '升級到 GOs PRO' : '解鎖捲字 Pro', style: ts(F.title, w: w7, c: p.ink)),
              const SizedBox(height: 8),
              Text('大考詞彙和考古題永遠免費，捲字 Pro 包含額外進階功能。', textAlign: TextAlign.center, style: ts(F.sub, c: p.sec)),
              const SizedBox(height: 22),
              if (owned)
                _box(
                  p,
                  Column(children: [
                    Text('你已經有 GOs PRO', style: ts(F.headline, w: w6, c: p.ink)),
                    const SizedBox(height: 6),
                    Text(_pro.devUnlocked ? '開發版已解鎖所有 Pro 功能。' : '捲字、校板和之後推出的 App 都能用 Pro 功能。',
                        textAlign: TextAlign.center, style: ts(F.sub, c: p.sec)),
                  ]),
                )
              else ...[
                Segmented<ProPeriod>(
                  items: const [(ProPeriod.monthly, '月繳'), (ProPeriod.yearly, '年繳')],
                  value: _period,
                  onChanged: (v) => setState(() => _period = v),
                ),
                const SizedBox(height: 16),
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _card(p, ProPlan.juango)),
                    const SizedBox(width: 12),
                    Expanded(child: _card(p, ProPlan.gos)),
                  ]),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    '訂閱 GOs PRO，解鎖包含捲字、校板和所有即將推出的 App 之進階功能。',
                    style: ts(F.foot, c: p.sec),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              _box(
                p,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _feature(p, Icons.all_inclusive_rounded, '「我的單字」不限個數', '免費版最多 1000 個'),
                  _feature(p, Icons.translate_rounded, '內建 AI 翻譯與例句', '不用自己填 API key'),
                  _feature(p, Icons.bolt_rounded, '單字對戰不限場次', '免費版每天 10 場'),
                  _feature(p, Icons.insights_rounded, '進階統計', '每週報告、常錯字、學測詞彙涵蓋率'),
                  _feature(p, Icons.palette_rounded, '額外主題色和 App 圖示', '即將推出'),
                  _feature(p, Icons.auto_awesome_rounded, '更多即將推出的功能', '包含訂閱期間所有推出的新功能', last: true),
                ]),
              ),
              if (!owned) ...[
                const SizedBox(height: 22),
                PrimaryButton(
                  label: upgrade ? '升級到 GOs PRO' : '免費試用 7 天',
                  width: double.infinity,
                  onTap: _busy ? null : () => _run(() => _pro.purchase(_plan, _period)),
                ),
                const SizedBox(height: 8),
                Text(
                  upgrade
                      ? '改成 NT\$$price / ${_period.unit}，剩下的捲字 Pro 費用由 Google Play 按比例折抵。'
                      : '試用結束後 NT\$$price / ${_period.unit}，自動續訂。',
                  textAlign: TextAlign.center,
                  style: ts(F.foot, c: p.sec),
                ),
              ],
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _link(p, '恢復購買', () => _run(_pro.restore)),
                const SizedBox(width: 22),
                _link(p, '有兌換碼？', () => _open(ProStore.redeem)),
              ]),
              const SizedBox(height: 18),
              Text(
                '訂閱會自動續訂。首次訂閱可免費試用 7 天，試用結束才開始扣款。可以隨時在 Google Play 的「付款和訂閱 › 訂閱」取消。',
                textAlign: TextAlign.center,
                style: ts(F.cap, c: p.sec),
              ),
              const SizedBox(height: 8),
              Text('Pro 到期後，超過 1000 個的單字會在 30 天後從最早加入的開始刪除，刪除前會通知你。',
                  textAlign: TextAlign.center, style: ts(F.cap, c: p.sec)),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _link(p, '服務條款', () => _open(ProStore.terms), small: true),
                const SizedBox(width: 16),
                _link(p, '隱私權政策', () => _open(ProStore.privacy), small: true),
              ]),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _box(Palette p, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
        child: child,
      );

  Widget _card(Palette p, ProPlan plan) {
    final selected = _plan == plan, current = _held == plan;
    final price = plan.price(_period);
    return Semantics(
      selected: selected,
      button: true,
      child: Tap(
        onTap: current ? null : () => setState(() => _plan = plan),
        child: Opacity(
          opacity: current ? .6 : 1,
          child: Container(
            height: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: selected ? p.accent : Colors.transparent, width: 2.5),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(plan.label, style: ts(F.headline, w: w6, c: p.ink))),
                if (plan == ProPlan.gos && !current)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(99)),
                    child: Text('推薦', style: ts(F.cap2, w: w7, c: p.onAccent)),
                  ),
              ]),
              const SizedBox(height: 4),
              Text(plan.blurb, style: ts(F.cap, c: p.sec)),
              const SizedBox(height: 6),
              const Spacer(),
              Text('NT\$$price', style: ts(26, w: w7, c: p.ink)),
              Text(_period == ProPeriod.yearly ? '每年・約 NT\$${price ~/ 12} / 月' : '每月', style: ts(F.cap, c: p.sec)),
              if (current) ...[const SizedBox(height: 4), Text('目前方案', style: ts(F.cap, w: w7, c: p.accent))],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _feature(Palette p, IconData icon, String title, String? sub, {bool last = false}) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 24, child: Icon(icon, size: 20, color: p.accent)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: ts(F.sub, w: w6, c: p.ink)),
              if (sub != null) Text(sub, style: ts(F.cap, c: p.sec)),
            ]),
          ),
        ]),
      );

  Widget _link(Palette p, String label, VoidCallback onTap, {bool small = false}) =>
      Tap(onTap: onTap, child: Text(label, style: ts(small ? F.foot : F.sub, w: w6, c: p.accent)));
}

// MARK: 設定 › 捲字 Pro

class ProSettingsPage extends StatelessWidget {
  const ProSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ProStore.shared,
        builder: (context, _) {
          final p = Palette.of(context);
          final pro = ProStore.shared;
          final plan = pro.plan;
          final String status;
          if (pro.devUnlocked) {
            status = '開發版：已解鎖所有 Pro 功能';
          } else if (plan == null) {
            status = '「我的單字」最多 1000 個，大考詞彙不算';
          } else {
            final e = pro.expires;
            status = '${plan.blurb}${e == null ? '' : '・${e.year}年${e.month}月${e.day}日 續訂'}';
          }
          return NavPage(title: '捲字 Pro', safeTop: false, slivers: [
            Sec(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(plan?.label ?? '免費版', style: ts(F.title2, w: w7, c: p.ink)),
                  const SizedBox(height: 6),
                  Text(status, style: ts(F.sub, c: p.sec)),
                ]),
              ),
            ]),
            Sec(footer: '大考詞彙和學測考古題不受付費限制。', children: [
              if (plan != ProPlan.gos || pro.devUnlocked)
                RowTile(
                  title: pro.devUnlocked ? '查看付費牆（展示用）' : (plan == ProPlan.juango ? '升級到 GOs PRO' : '查看 Pro 方案'),
                  titleColor: p.accent,
                  onTap: () => presentFull(context, const ProPaywall()),
                ),
              if (pro.isPro && !pro.devUnlocked) RowTile(title: '管理訂閱', titleColor: p.accent, onTap: () => _open(ProStore.manage)),
            ]),
          ]);
        },
      );
}
