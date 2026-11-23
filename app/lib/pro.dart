// 捲字 Pro 和 GOs PRO：方案、目前狀態、付費牆和「設定 › 捲字 Pro」。排版照 iOS 版 Pro.swift。
// 之後用 RevenueCat 購買（entitlement `juango_pro`，由 juango_pro_* 和 gos_pro_* 解鎖）；
// 商店還沒開通前，購買和恢復購買都會說明還不能用。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_page.dart';
import 'cloud.dart';
import 'dev_log.dart';
import 'theme.dart';
import 'widgets.dart';

/// 開發版（本機 battle 分支）直接當成 GOs PRO，所有付費功能都打開。main 一定是 false，這裡是 true
const devGosPro = false;

/// 捲字 Pro 只解鎖捲字；GOs PRO 解鎖 HowWeiChi 所有 App，包括之後推出的
enum ProPlan {
  juango('捲字 Pro', '只有捲字', 'juango'),
  gos('GOs PRO', '捲字與 GOs PRO 合作服務', 'gos');

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

/// 收在「更多方案」裡、不會自動續訂的方案
enum ProExtra {
  /// 180 天大考衝刺包：Google Play 訂閱底下的預付方案（效期 6 個月）；iOS 是非續訂型訂閱。再買天數會疊加
  pass180(
    '180 天大考衝刺包',
    300,
    'juango_pass_180',
    '捲字 Pro 180 天，不自動續訂，沒有試用。再買一次天數會往後加。',
  ),

  /// 火星贊助者：消耗型單次贊助，不解鎖功能，只給「🚀 火星贊助者」徽章，可以重複買
  tipMars(
    '火星贊助者',
    30,
    'juango_tip_mars',
    '單次贊助，不解鎖功能，獲得「🚀 火星贊助者」徽章，可以重複贊助。',
  );

  const ProExtra(this.label, this.price, this.productId, this.blurb);
  final String label, productId, blurb;
  final int price;
}

/// 已經做好的付費功能，開發版可以在「開發者選項」一個個關掉
enum ProFeature {
  words('「我的單字」不限個數'),
  battles('單字對戰不限場次'),
  textbook('課文書架不限課數');

  const ProFeature(this.title);
  final String title;
}

class ProStore extends ChangeNotifier {
  ProStore._() {
    unawaited(_loadDev());
    // 登入、登出、拿到帳號資訊時 Pro 狀態跟著變
    Cloud.shared.addListener(notifyListeners);
  }

  /// 開發者選項關掉的功能，照免費版運作
  final Set<ProFeature> devOff = {};

  bool has(ProFeature f) => isPro && !devOff.contains(f);

  Future<void> _loadDev() async {
    final names =
        (await SharedPreferences.getInstance()).getStringList('dev.proOff') ??
        const [];
    devOff.addAll(ProFeature.values.where((f) => names.contains(f.name)));
    notifyListeners();
  }

  Future<void> setDev(ProFeature f, bool on) async {
    on ? devOff.remove(f) : devOff.add(f);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setStringList('dev.proOff', [
      for (final x in devOff) x.name,
    ]);
    // 對戰每天的場次是伺服器算的，只對 battle_unlimited 裡的測試帳號有效
    if (f == ProFeature.battles) {
      try {
        await Cloud.shared.rpc('battle_dev_limit', {
          'p_paused': !on,
        }, const Duration(seconds: 10));
      } catch (e) {
        debugPrint('開發者選項：對戰場次沒有改成功：$e');
      }
    }
  }

  static final shared = ProStore._();

  /// 在商店買的方案（RevenueCat 還沒接上）
  ProPlan? _bought;

  /// 這個帳號有的方案：開發帳號是 GOs PRO，再來是伺服器上的方案（兌換碼、活動），最後是商店買的
  ProPlan? get plan =>
      devUnlocked ? ProPlan.gos : (_serverPlan ?? _bought);

  /// 伺服器算的方案（my_account 的 plan）
  ProPlan? get _serverPlan => switch (Cloud.shared.account?['plan']) {
    'gos' => ProPlan.gos,
    'juango' => ProPlan.juango,
    _ => null,
  };
  ProPeriod? period;
  DateTime? _expires;
  DateTime? get expires =>
      _expires ??
      DateTime.tryParse('${Cloud.shared.account?['expires_at'] ?? ''}')?.toLocal();

  /// 開發帳號：dev_testers 名單裡的帳號登入後打開（開發版 App 只要登入就打開）。
  /// 登出就跟免費版一樣，開發版的說明和開發者選項也不顯示
  bool get devUnlocked =>
      Cloud.shared.signedIn &&
      (devGosPro || Cloud.shared.account?['tester'] == true);

  bool get isPro => plan != null;

  static const notOpen = '商店還沒開通，App 上架後就能訂閱。';

  /// 這個 Google 帳號還能不能用 7 天免費試用（每個訂閱群組一生一次）。
  /// Google Play 只會把有資格的人的試用優惠傳回來；商店還沒開通前一律 false，付費牆就不寫「免費試用」
  bool introEligible = false;

  Future<void> purchase(ProPlan plan, ProPeriod period) async => throw notOpen;
  Future<void> purchaseExtra(ProExtra extra) async => throw notOpen;
  Future<void> restore() async => throw notOpen;

  static final terms = Uri.parse('https://howweichi-app.github.io/terms/');
  static final privacy = Uri.parse('https://howweichi-app.github.io/privacy/');
  static final manage = Uri.parse(
    'https://play.google.com/store/account/subscriptions?package=io.github.howweichi.juango',
  );
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

  /// 只有商店確認有試用資格才寫「7 天免費試用」
  bool get _trial => _pro.introEligible && _held == null;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      // 沒登入也能買；買完提醒可以登入，讓 iPhone 和 Android 共用 Pro
      if (mounted && !Cloud.shared.signedIn) {
        await showAlert(
          context,
          '要同步到其他裝置嗎？',
          message: '若需在 iPhone 與 Android 之間同步 Pro 資格（含 GOs PRO 套裝）與學習進度，請登入 Email 帳號綁定。',
          actions: [
            const AlertAction('之後再說'),
            AlertAction(
              '登入 Email',
              bold: true,
              onTap: () => pushPage(context, const AccountPage()),
            ),
          ],
        );
      }
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
            child: Column(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 44, color: p.accent),
                const SizedBox(height: 8),
                Text(
                  upgrade ? '升級到 GOs PRO' : '解鎖捲字 Pro',
                  style: ts(F.title, w: w7, c: p.ink),
                ),
                const SizedBox(height: 8),
                Text(
                  '大考詞彙和考古題永遠免費，捲字 Pro 包含額外進階功能。',
                  textAlign: TextAlign.center,
                  style: ts(F.sub, c: p.sec),
                ),
                const SizedBox(height: 22),
                if (owned)
                  _box(
                    p,
                    Column(
                      children: [
                        Text(
                          '你已經有 GOs PRO',
                          style: ts(F.headline, w: w6, c: p.ink),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _pro.devUnlocked
                              ? '開發版已解鎖所有 Pro 功能。'
                              : '捲字 Pro 與 GOs PRO 合作服務的完整功能都能使用。',
                          textAlign: TextAlign.center,
                          style: ts(F.sub, c: p.sec),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Segmented<ProPeriod>(
                    items: const [
                      (ProPeriod.monthly, '月繳'),
                      (ProPeriod.yearly, '年繳'),
                    ],
                    value: _period,
                    onChanged: (v) => setState(() => _period = v),
                  ),
                  const SizedBox(height: 16),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _card(p, ProPlan.juango)),
                        const SizedBox(width: 12),
                        Expanded(child: _card(p, ProPlan.gos)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: Text(
                      '解鎖捲字 Pro 與 GOs PRO 合作服務完整功能，並享有未來新服務優先體驗權。',
                      style: ts(F.foot, c: p.sec),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                _box(
                  p,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _feature(
                        p,
                        Icons.all_inclusive_rounded,
                        '「我的單字」不限個數',
                        '免費版最多 1000 個',
                      ),
                      _feature(
                        p,
                        Icons.translate_rounded,
                        'AI 智慧引擎',
                        '無上限智慧例句生成、課文掃描自動校對與免填 Key 翻譯',
                      ),
                      _feature(p, Icons.bolt_rounded, '單字對戰不限場次', '免費版每天 10 場'),
                      _feature(
                        p,
                        Icons.auto_stories_rounded,
                        '課文書架不限課數',
                        '掃描課文變成電子書，免費版可試用 1 課（最多 3 頁）',
                      ),
                      _feature(
                        p,
                        Icons.insights_rounded,
                        '進階統計',
                        '每週報告、常錯字、學測詞彙涵蓋率',
                      ),
                      _feature(
                        p,
                        Icons.palette_rounded,
                        '額外主題色和 App 圖示',
                        '即將推出',
                        last: true,
                      ),
                    ],
                  ),
                ),
                if (!owned) ...[
                  const SizedBox(height: 22),
                  PrimaryButton(
                    label: upgrade
                        ? '升級到 GOs PRO'
                        : (_trial ? '免費試用 7 天' : '訂閱 ${_plan.label}'),
                    width: double.infinity,
                    onTap: _busy
                        ? null
                        : () => _run(() => _pro.purchase(_plan, _period)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    upgrade
                        ? '改成 NT\$$price / ${_period.unit}，剩下的捲字 Pro 費用由 Google Play 按比例折抵。'
                        : _trial
                        ? '試用 7 天後 NT\$$price / ${_period.unit}，自動續訂。'
                        : 'NT\$$price / ${_period.unit}，自動續訂。',
                    textAlign: TextAlign.center,
                    style: ts(F.foot, c: p.sec),
                  ),
                ],
                const SizedBox(height: 18),
                _more(p),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _link(p, '恢復購買', () => _run(_pro.restore)),
                    const SizedBox(width: 22),
                    _link(p, '有兌換碼？', () => _open(ProStore.redeem)),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '${_trial ? '首次訂閱可免費試用 7 天，試用結束才開始扣款。' : ''}月繳和年繳會自動續訂：目前期間結束前 24 小時內自動扣款續訂，可以隨時在 Google Play 的「付款和訂閱 › 訂閱」取消。180 天大考衝刺包和火星贊助者不會自動扣款。',
                  textAlign: TextAlign.center,
                  style: ts(F.cap, c: p.sec),
                ),
                const SizedBox(height: 8),
                Text(
                  'Pro 到期後不會刪除任何單字：超過 1000 個時暫停新增，原有單字照常瀏覽和複習。',
                  textAlign: TextAlign.center,
                  style: ts(F.cap, c: p.sec),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _link(p, '服務條款', () => _open(ProStore.terms), small: true),
                    const SizedBox(width: 16),
                    _link(
                      p,
                      '隱私權政策',
                      () => _open(ProStore.privacy),
                      small: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 「更多方案」：預設收合，主畫面只留兩個訂閱
  Widget _more(Palette p) => Material(
    color: p.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.lg),
    ),
    clipBehavior: Clip.antiAlias,
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        iconColor: p.ink,
        collapsedIconColor: p.ink,
        title: Text('更多方案', style: ts(F.sub, w: w6, c: p.ink)),
        children: [
          for (final e in ProExtra.values)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.label, style: ts(F.sub, w: w6, c: p.ink)),
                        const SizedBox(height: 3),
                        Text(e.blurb, style: ts(F.cap, c: p.sec)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => _pro.purchaseExtra(e)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.accent,
                      side: BorderSide(color: p.accent),
                    ),
                    child: Text(
                      'NT\$${e.price}',
                      style: ts(F.sub, w: w7, c: p.accent),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _box(Palette p, Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: p.card,
      borderRadius: BorderRadius.circular(Radii.lg),
    ),
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
              border: Border.all(
                color: selected ? p.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.label,
                        style: ts(F.headline, w: w6, c: p.ink),
                      ),
                    ),
                    if (plan == ProPlan.gos && !current)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          '推薦',
                          style: ts(F.cap2, w: w7, c: p.onAccent),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(plan.blurb, style: ts(F.cap, c: p.sec)),
                const SizedBox(height: 6),
                const Spacer(),
                Text(
                  'NT\$$price',
                  style: ts(26, w: w7, c: p.ink),
                ),
                Text(
                  _period == ProPeriod.yearly
                      ? '每年・約 NT\$${price ~/ 12} / 月'
                      : '每月',
                  style: ts(F.cap, c: p.sec),
                ),
                if (current) ...[
                  const SizedBox(height: 4),
                  Text(
                    '目前方案',
                    style: ts(F.cap, w: w7, c: p.accent),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _feature(
    Palette p,
    IconData icon,
    String title,
    String? sub, {
    bool last = false,
  }) => Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 24, child: Icon(icon, size: 20, color: p.accent)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: ts(F.sub, w: w6, c: p.ink),
              ),
              if (sub != null) Text(sub, style: ts(F.cap, c: p.sec)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _link(
    Palette p,
    String label,
    VoidCallback onTap, {
    bool small = false,
  }) => Tap(
    onTap: onTap,
    child: Text(
      label,
      style: ts(small ? F.foot : F.sub, w: w6, c: p.accent),
    ),
  );
}

// MARK: 設定 › 捲字 Pro

class ProSettingsPage extends StatelessWidget {
  const ProSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([ProStore.shared, Cloud.shared]),
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
        status =
            '${plan.blurb}${e == null ? '' : '・${e.year}年${e.month}月${e.day}日 續訂'}';
      }
      return NavPage(
        title: '捲字 Pro',
        safeTop: false,
        slivers: [
          Sec(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan?.label ?? '免費版',
                      style: ts(F.title2, w: w7, c: p.ink),
                    ),
                    const SizedBox(height: 6),
                    Text(status, style: ts(F.sub, c: p.sec)),
                  ],
                ),
              ),
            ],
          ),
          Sec(
            footer: '大考詞彙和學測考古題不受付費限制。',
            children: [
              if (plan != ProPlan.gos || pro.devUnlocked)
                RowTile(
                  title: pro.devUnlocked
                      ? '查看付費牆（展示用）'
                      : (plan == ProPlan.juango ? '升級到 GOs PRO' : '查看 Pro 方案'),
                  titleColor: p.accent,
                  onTap: () => presentFull(context, const ProPaywall()),
                ),
              if (pro.isPro && !pro.devUnlocked)
                RowTile(
                  title: '管理訂閱',
                  titleColor: p.accent,
                  onTap: () => _open(ProStore.manage),
                ),
            ],
          ),
          if (pro.devUnlocked)
            Sec(
              header: '開發者選項',
              footer:
                  '關掉的功能會照免費版運作，方便測試。對戰場次只對測試帳號有效。開發版的 Pro 綁在登入的帳號上，登出就恢復免費版。',
              children: [
                for (final f in ProFeature.values)
                  SwitchRow(
                    title: f.title,
                    value: !pro.devOff.contains(f),
                    onChanged: (v) => unawaited(pro.setDev(f, v)),
                  ),
                RowTile(
                  title: pro.devOff.length == ProFeature.values.length
                      ? '全部打開'
                      : '全部關閉',
                  titleColor: p.accent,
                  onTap: () {
                    final on = pro.devOff.length == ProFeature.values.length;
                    for (final f in ProFeature.values) {
                      unawaited(pro.setDev(f, on));
                    }
                  },
                ),
              ],
            ),
          if (pro.devUnlocked)
            Sec(
              footer: 'Log 只存在這支手機，按「回報問題」送出時才會連同你的說明一起上傳。',
              children: [
                RowTile(
                  leading: Icon(
                    Icons.receipt_long_rounded,
                    size: 22,
                    color: p.accent,
                  ),
                  title: 'Log 紀錄',
                  chevron: true,
                  onTap: () => pushPage(context, const DevLogPage()),
                ),
                RowTile(
                  leading: Icon(
                    Icons.feedback_outlined,
                    size: 22,
                    color: p.accent,
                  ),
                  title: '回報問題',
                  chevron: true,
                  onTap: () => pushPage(context, const DevReportPage()),
                ),
              ],
            ),
        ],
      );
    },
  );
}
