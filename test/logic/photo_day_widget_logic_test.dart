import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/logic/photo_day_widget_logic.dart';

void main() {
  group('PhotoDayWidgetLogic.resolveSelectedWidgetId', () {
    test('returns null when there are no widget instances', () {
      expect(PhotoDayWidgetLogic.resolveSelectedWidgetId([], null), isNull);
    });

    test('keeps current selection when it still exists', () {
      expect(
        PhotoDayWidgetLogic.resolveSelectedWidgetId([101, 102], 101),
        101,
      );
    });

    test('falls back to last widget when current selection is missing', () {
      expect(
        PhotoDayWidgetLogic.resolveSelectedWidgetId([101, 102], 999),
        102,
      );
    });

    test('picks last widget when nothing was selected before', () {
      expect(
        PhotoDayWidgetLogic.resolveSelectedWidgetId([101, 102], null),
        102,
      );
    });
  });

  group('PhotoDayWidgetLogic.resolveModeChange', () {
    test('re-tapping random requests next random photo', () {
      final result = PhotoDayWidgetLogic.resolveModeChange(
        currentMode: 'random',
        requestedMode: 'random',
      );

      expect(result.mode, 'random');
      expect(result.forceNext, isTrue);
    });

    test('switching to custom does not request next random photo', () {
      final result = PhotoDayWidgetLogic.resolveModeChange(
        currentMode: 'random',
        requestedMode: 'custom',
      );

      expect(result.mode, 'custom');
      expect(result.forceNext, isFalse);
    });

    test('switching from custom to random does not force next by itself', () {
      final result = PhotoDayWidgetLogic.resolveModeChange(
        currentMode: 'custom',
        requestedMode: 'random',
      );

      expect(result.mode, 'random');
      expect(result.forceNext, isFalse);
    });
  });

  group('PhotoDayWidgetLogic.resolveState', () {
    test('partner display uses widget preview path by default', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'random',
        display: 'partner',
        widgetPreviewPath: '/widget/partner.jpg',
      );

      expect(result.previewShowsPartner, isTrue);
      expect(result.widgetPhotoPath, '/widget/partner.jpg');
      expect(result.partnerPhotoPath, '/widget/partner.jpg');
      expect(result.previewPath(), '/widget/partner.jpg');
    });

    test('mine + custom prefers local custom path', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'custom',
        display: 'mine',
        widgetPreviewPath: '/widget/partner.jpg',
        widgetCustomPath: '/local/mine.jpg',
        myPhotoUrl: 'https://cdn.example.com/mine.jpg',
      );

      expect(result.previewShowsPartner, isFalse);
      expect(result.ownPhotoPath, '/local/mine.jpg');
      expect(result.previewPath(), '/local/mine.jpg');
    });

    test('mine + custom falls back to uploaded myPhotoUrl when local file is absent', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'custom',
        display: 'mine',
        widgetPreviewPath: '/widget/partner.jpg',
        widgetCustomPath: null,
        myPhotoUrl: 'https://cdn.example.com/mine.jpg',
      );

      expect(result.ownPhotoPath, 'https://cdn.example.com/mine.jpg');
      expect(result.previewPath(), 'https://cdn.example.com/mine.jpg');
    });

    test('mine preview keeps own photo even in random mode', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'random',
        display: 'mine',
        widgetPreviewPath: '/widget/random.jpg',
        fallbackOwnPhotoPath: '/old/own.jpg',
      );

      expect(result.previewShowsPartner, isFalse);
      expect(result.ownPhotoPath, '/old/own.jpg');
      expect(result.previewPath(), '/old/own.jpg');
    });

    test('partner path falls back when widget preview is empty', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'random',
        display: 'partner',
        widgetPreviewPath: '',
        fallbackPartnerPhotoPath: '/cached/partner.jpg',
      );

      expect(result.partnerPhotoPath, '/cached/partner.jpg');
      expect(result.previewPath(), '/cached/partner.jpg');
    });

    test('previewPath can be overridden for UI toggle', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 1,
        mode: 'custom',
        display: 'partner',
        widgetPreviewPath: '/widget/partner.jpg',
        widgetCustomPath: '/local/mine.jpg',
      );

      expect(result.previewPath(), '/widget/partner.jpg');
      expect(
        result.previewPath(previewShowsPartnerOverride: false),
        '/local/mine.jpg',
      );
    });

    test('loaded widget state resolves exact widget instance configuration', () {
      final selectedWidgetId = PhotoDayWidgetLogic.resolveSelectedWidgetId(
        [11, 12],
        11,
      );
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: selectedWidgetId,
        mode: 'custom',
        display: 'mine',
        widgetPreviewPath: '/widget12-preview.jpg',
        widgetCustomPath: '/widget11-custom.jpg',
      );

      expect(result.selectedWidgetId, 11);
      expect(result.mode, 'custom');
      expect(result.display, 'mine');
      expect(result.ownPhotoPath, '/widget11-custom.jpg');
    });

    test('selecting another widget resolves that widget preview and display', () {
      final result = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: 22,
        mode: 'random',
        display: 'partner',
        widgetPreviewPath: '/widget22-preview.jpg',
        fallbackOwnPhotoPath: '/widget11-custom.jpg',
      );

      expect(result.selectedWidgetId, 22);
      expect(result.previewShowsPartner, isTrue);
      expect(result.widgetPhotoPath, '/widget22-preview.jpg');
      expect(result.previewPath(), '/widget22-preview.jpg');
    });
  });
}
