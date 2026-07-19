class PhotoDayWidgetResolvedState {
  const PhotoDayWidgetResolvedState({
    required this.selectedWidgetId,
    required this.mode,
    required this.display,
    required this.previewShowsPartner,
    required this.ownPhotoPath,
    required this.widgetPhotoPath,
    required this.partnerPhotoPath,
  });

  final int? selectedWidgetId;
  final String mode;
  final String display;
  final bool previewShowsPartner;
  final String? ownPhotoPath;
  final String? widgetPhotoPath;
  final String? partnerPhotoPath;

  String? previewPath({bool? previewShowsPartnerOverride}) {
    final showsPartner = previewShowsPartnerOverride ?? previewShowsPartner;
    return showsPartner ? (widgetPhotoPath ?? partnerPhotoPath) : ownPhotoPath;
  }
}

class PhotoDayWidgetModeChange {
  const PhotoDayWidgetModeChange({
    required this.mode,
    required this.forceNext,
  });

  final String mode;
  final bool forceNext;
}

class PhotoDayWidgetLogic {
  const PhotoDayWidgetLogic._();

  static int? resolveSelectedWidgetId(List<int> widgetIds, int? currentSelection) {
    if (widgetIds.isEmpty) return null;
    if (currentSelection != null && widgetIds.contains(currentSelection)) {
      return currentSelection;
    }
    return widgetIds.last;
  }

  static PhotoDayWidgetModeChange resolveModeChange({
    required String currentMode,
    required String requestedMode,
  }) {
    return PhotoDayWidgetModeChange(
      mode: requestedMode,
      forceNext: requestedMode == 'random' && currentMode == 'random',
    );
  }

  static PhotoDayWidgetResolvedState resolveState({
    required int? selectedWidgetId,
    required String mode,
    required String display,
    String? widgetPreviewPath,
    String? widgetCustomPath,
    String? myPhotoUrl,
    String? fallbackOwnPhotoPath,
    String? fallbackPartnerPhotoPath,
  }) {
    final normalizedWidgetPreview = _normalized(widgetPreviewPath);
    final normalizedCustomPath = _normalized(widgetCustomPath);
    final normalizedMyPhotoUrl = _normalized(myPhotoUrl);
    final normalizedFallbackOwn = _normalized(fallbackOwnPhotoPath);
    final normalizedFallbackPartner = _normalized(fallbackPartnerPhotoPath);

    final ownPhotoPath =
        normalizedCustomPath ?? normalizedMyPhotoUrl ?? normalizedFallbackOwn;

    final partnerPhotoPath = normalizedWidgetPreview ?? normalizedFallbackPartner;

    return PhotoDayWidgetResolvedState(
      selectedWidgetId: selectedWidgetId,
      mode: mode,
      display: display,
      previewShowsPartner: display == 'partner',
      ownPhotoPath: ownPhotoPath,
      widgetPhotoPath: normalizedWidgetPreview,
      partnerPhotoPath: partnerPhotoPath,
    );
  }

  static String? _normalized(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}
