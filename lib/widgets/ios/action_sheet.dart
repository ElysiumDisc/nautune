import 'package:flutter/cupertino.dart';

/// One choice in [showNautuneActionSheet].
class NautuneSheetAction<T> {
  const NautuneSheetAction({
    required this.label,
    required this.value,
    this.icon,
    this.destructive = false,
    this.isDefault = false,
  });

  final String label;
  final T value;
  final IconData? icon;
  final bool destructive;
  final bool isDefault;
}

/// iOS action sheet sliding up from the bottom. Resolves to the chosen
/// action's value, or null when cancelled.
Future<T?> showNautuneActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<NautuneSheetAction<T>> actions,
  String cancelLabel = 'Cancel',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: title == null ? null : Text(title),
      message: message == null ? null : Text(message),
      actions: [
        for (final action in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: action.destructive,
            isDefaultAction: action.isDefault,
            onPressed: () => Navigator.of(sheetContext).pop(action.value),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (action.icon != null) ...[
                  Icon(action.icon, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(action.label, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: Text(cancelLabel),
      ),
    ),
  );
}
