import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';

void main() {
  test('trailer targets carry their source and compare by it', () {
    const EYZFlowSource source = EYZFlowSource(
      id: 'trailer-a',
      title: 'Trailer A',
    );

    expect(
      const VideoplayerTrailerTarget(source),
      const VideoplayerTrailerTarget(source),
    );
    expect(const VideoplayerTrailerTarget(source).source.id, 'trailer-a');
  });
}
