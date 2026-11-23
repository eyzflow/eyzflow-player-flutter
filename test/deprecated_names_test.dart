// ignore_for_file: deprecated_member_use_from_same_package

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the pre-EYF-225 names still build and mean the same types', () {
    const EyzflowSourceType film = EyzflowFilm('a');
    expect(film, const EYZFlowFilm('a'));
    expect(const EyzflowTrailer('a'), isA<EYZFlowTrailer>());
    expect(const EyzflowEndpoints(), isA<EYZFlowEndpoints>());
    expect(EyzflowLanguageNames, EYZFlowLanguageNames);
    expect(EyzflowPlayer, EYZFlowPlayer);
    expect(EyzflowPlayerStatus, EYZFlowPlayerStatus);
    setEyzflowPlayerLanguage(null);
  });
}
