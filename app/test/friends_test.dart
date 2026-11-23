import 'package:flutter_test/flutter_test.dart';
import 'package:juango/friends.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

void main() {
  test('好友代碼和連結', () {
    expect(friendCode('a1b2c3d4e5'), 'A1B2C3D4E5');
    expect(friendLink('a1b2c3d4e5'), 'juango://friend/A1B2C3D4E5');
    expect(roomLink('ab12'), 'juango://room/AB12');
    expect(Uri.parse(friendLink('a1b2')).host, 'friend');
    expect(Uri.parse(roomLink('ab12')).pathSegments.first, 'AB12');
  });

  test('QR code 編得出來', () {
    final qr = QrImage(QrCode(payload: QrPayload.fromString(friendLink('a1b2c3d4e5'))));
    expect(qr.moduleCount, greaterThanOrEqualTo(21));
    var dark = 0;
    for (var y = 0; y < qr.moduleCount; y++) {
      for (var x = 0; x < qr.moduleCount; x++) {
        if (qr.isDark(y, x)) dark++;
      }
    }
    expect(dark, greaterThan(0));
  });

  test('好友和公開房間資料', () {
    final f = Friend({'name': '小明', 'pid': 'abc', 'rating': 1200, 'tier': 2, 'tier_name': '白銀', 'room': 'AB12'});
    expect(f.room, 'AB12');
    expect(f.tierText, '白銀');
    final r = PublicRoom({'name': '小華', 'pid': 'def', 'rating': 900, 'tier': 1, 'code': 'CD34'});
    expect(r.code, 'CD34');
  });

  testWidgets('QR code 畫面', (t) async {
    await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: Center(child: QrView(data: 'juango://friend/ABC'))));
    expect(find.byType(QrView), findsOneWidget);
  });
}
