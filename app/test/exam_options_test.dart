import 'package:flutter_test/flutter_test.dart';
import 'package:juango/dictionary.dart';

void main() {
  test('同程度、字首一樣的字比較像大考選項', () {
    final r = Dict.levelRank('3');
    expect(
      Dict.examScore('impress', r, 'improve', r),
      greaterThan(Dict.examScore('impress', r, 'banana', r)),
    );
    expect(
      Dict.examScore('impress', r, 'improve', r),
      greaterThan(Dict.examScore('impress', r, 'improve', Dict.levelRank('6'))),
    );
    expect(
      Dict.examScore('attention', r, 'addition', r),
      greaterThan(Dict.examScore('attention', r, 'cat', r)),
    );
  });

  test('其他字表的程度', () {
    expect(Dict.levelRank('國中小'), 0);
    expect(Dict.levelRank('托福'), 6);
    expect(Dict.levelRank('多益'), 4);
  });
}
