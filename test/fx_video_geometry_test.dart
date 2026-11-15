import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/fx_display_settings.dart';
import 'package:fantasy_tv/services/fx_video_geometry.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';

/// 画面比例几何的回归（ASPECT_REAL 2026-11-15）。
///
/// 用户报的 bug：播放画面被拉变形 —— 容器写死 16:9，原生又是 MATCH_PARENT
/// 的 TextureView（不认比例）。这里钉住三件事：
///   1. 比例只从视频真实宽高来，拿不到才退回 16:9；
///   2. 三档语义：适应 = 等比完整显示、填充 = 等比裁满、拉伸 = 铺满（会变形）；
///   3. 播放区高度：宽片收窄、竖屏 / 4:3 停在 16:9 高度（铺满高度左右留黑）。
void main() {
  group('视频比例', () {
    test('真实宽高', () {
      expect(fxVideoAspectOf(1920, 800), closeTo(2.4, 1e-9));
      expect(fxVideoAspectOf(1080, 1920), closeTo(0.5625, 1e-9));
      expect(fxVideoAspectOf(640, 480), closeTo(4 / 3, 1e-9));
      // 缺失 / 0 / 负数一律不给比例，由调用方退回 16:9。
      expect(fxVideoAspectOf(null, 1080), isNull);
      expect(fxVideoAspectOf(1920, null), isNull);
      expect(fxVideoAspectOf(0, 0), isNull);
      expect(fxVideoAspectOf(-1920, 1080), isNull);
    });

    test('拿不到时退回 16:9，解码尺寸可兜底', () {
      expect(fxVideoAspectOrFallback(), kFxFallbackVideoAspect);
      expect(
        fxVideoAspectOrFallback(width: 0, height: 0),
        kFxFallbackVideoAspect,
      );
      // 显示尺寸缺失时用解码尺寸。
      expect(
        fxVideoAspectOrFallback(rawWidth: 1080, rawHeight: 1920),
        closeTo(0.5625, 1e-9),
      );
      // 显示尺寸优先。
      expect(
        fxVideoAspectOrFallback(
          width: 1920,
          height: 800,
          rawWidth: 1080,
          rawHeight: 1920,
        ),
        closeTo(2.4, 1e-9),
      );
    });
  });

  group('三档适配', () {
    const container = Size(400, 225); // 竖屏页里的 16:9 播放区

    test('适应 = 等比完整放进容器（不裁不拉）', () {
      // 2.4:1 电影：宽铺满，上下留黑。
      final wide = fxFitSize(container, 2.4, BoxFit.contain);
      expect(wide.width, closeTo(400, 1e-6));
      expect(wide.height, closeTo(400 / 2.4, 1e-6));
      expect(wide.width / wide.height, closeTo(2.4, 1e-6));
      // 9:16 竖屏短剧：高铺满，左右留黑（不是被压扁）。
      final vertical = fxFitSize(container, 0.5625, BoxFit.contain);
      expect(vertical.height, closeTo(225, 1e-6));
      expect(vertical.width, closeTo(225 * 0.5625, 1e-6));
      expect(vertical.width / vertical.height, closeTo(0.5625, 1e-6));
      // 4:3 老片：高铺满，左右留黑。
      final old = fxFitSize(container, 4 / 3, BoxFit.contain);
      expect(old.width / old.height, closeTo(4 / 3, 1e-6));
    });

    test('填充 = 等比盖住容器（超出裁掉，比例不变）', () {
      final wide = fxFitSize(container, 2.4, BoxFit.cover);
      expect(wide.height, closeTo(225, 1e-6));
      expect(wide.width, closeTo(225 * 2.4, 1e-6));
      expect(wide.width, greaterThan(container.width));
      expect(wide.width / wide.height, closeTo(2.4, 1e-6));
      final vertical = fxFitSize(container, 0.5625, BoxFit.cover);
      expect(vertical.width, closeTo(400, 1e-6));
      expect(vertical.width / vertical.height, closeTo(0.5625, 1e-6));
    });

    test('拉伸 = 直接铺满容器（只有这一档会变形）', () {
      final box = fxFitSize(container, 2.4, BoxFit.fill);
      expect(box, container);
    });
  });

  group('播放区高度', () {
    test('宽片容器收窄，竖屏 / 4:3 停在 16:9 高度', () {
      const width = 400.0;
      final baseline = width * 9 / 16; // 225
      // 1920×800 电影：按真实比例算，不留多余黑边。
      expect(
        fxPlayerStageHeight(width: width, videoRatio: 2.4),
        closeTo(width / 2.4, 1e-6),
      );
      // 1080×1920 竖屏短剧：停在 16:9 高度，画面铺满高度、左右留黑。
      expect(
        fxPlayerStageHeight(width: width, videoRatio: 1080 / 1920),
        closeTo(baseline, 1e-6),
      );
      // 4:3 老片同理。
      expect(
        fxPlayerStageHeight(width: width, videoRatio: 4 / 3),
        closeTo(baseline, 1e-6),
      );
      // 正好 16:9：还是原来那个高度。
      expect(
        fxPlayerStageHeight(width: width, videoRatio: 16 / 9),
        closeTo(baseline, 1e-6),
      );
      // 比例未知 / 非法：退回 16:9 高度。
      expect(
        fxPlayerStageHeight(width: width, videoRatio: 0),
        closeTo(baseline, 1e-6),
      );
      expect(
        fxPlayerStageHeight(width: width, videoRatio: double.nan),
        closeTo(baseline, 1e-6),
      );
      expect(fxPlayerStageHeight(width: 0, videoRatio: 16 / 9), 0);
    });

    test('容器比例 = 视频比例（所以纹理不会被拉变形）', () {
      for (final ratio in <double>[2.4, 16 / 9, 4 / 3, 1, 9 / 16]) {
        const width = 360.0;
        final height = fxPlayerStageHeight(width: width, videoRatio: ratio);
        final box = fxFitSize(Size(width, height), ratio, BoxFit.contain);
        // 高度不超过 16:9 基准；宽片正好铺满宽，更方的片子铺满高。
        expect(height, lessThanOrEqualTo(width * 9 / 16 + 1e-9));
        expect(
          box.width / box.height,
          closeTo(ratio, 1e-6),
          reason: 'ratio=$ratio',
        );
      }
    });
  });

  group('FxVideoStage 布局', () {
    Future<Size> pumpStage(
      WidgetTester tester, {
      required FxAspectMode mode,
      required double videoRatio,
    }) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              height: 225,
              child: FxVideoStage(
                mode: mode,
                videoRatio: videoRatio,
                child: const ColoredBox(
                  key: ValueKey<String>('canvas'),
                  color: Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const ValueKey<String>('canvas')));
    }

    testWidgets('适应：2.4:1 画面在 16:9 区域里上下留黑', (tester) async {
      final size = await pumpStage(
        tester,
        mode: FxAspectMode.contain,
        videoRatio: 2.4,
      );
      expect(size.width, closeTo(400, 1e-6));
      expect(size.height, closeTo(400 / 2.4, 1e-6));
    });

    testWidgets('适应：竖屏短剧铺满高度、左右留黑', (tester) async {
      final size = await pumpStage(
        tester,
        mode: FxAspectMode.contain,
        videoRatio: 1080 / 1920,
      );
      expect(size.height, closeTo(225, 1e-6));
      expect(size.width, closeTo(225 * 1080 / 1920, 1e-6));
    });

    testWidgets('填充：画面盖住容器（比容器大，靠裁切）', (tester) async {
      final size = await pumpStage(
        tester,
        mode: FxAspectMode.cover,
        videoRatio: 2.4,
      );
      expect(size.height, closeTo(225, 1e-6));
      expect(size.width, closeTo(225 * 2.4, 1e-6));
    });

    testWidgets('拉伸：画面正好是容器大小', (tester) async {
      final size = await pumpStage(
        tester,
        mode: FxAspectMode.fill,
        videoRatio: 2.4,
      );
      expect(size, const Size(400, 225));
    });

    testWidgets('固定 16:9 档：先框 16:9，画面在框内裁满', (tester) async {
      final size = await pumpStage(
        tester,
        mode: FxAspectMode.ratio16x9,
        videoRatio: 2.4,
      );
      // 框 = 400×225（容器本来就是 16:9），2.4:1 的画面裁满 → 540×225。
      expect(size.height, closeTo(225, 1e-6));
      expect(size.width, closeTo(225 * 2.4, 1e-6));
    });
  });
}
