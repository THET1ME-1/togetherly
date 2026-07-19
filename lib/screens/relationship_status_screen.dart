import 'package:flutter/material.dart';
import '../models/pair_data.dart';
import '../models/relationship_status.dart';
import '../services/locale_service.dart';
import '../theme/theme_scope.dart';
import '../widgets/common/m3_loading.dart';

class RelationshipStatusScreen extends StatefulWidget {
  final PairData pairData;

  const RelationshipStatusScreen({super.key, required this.pairData});

  @override
  State<RelationshipStatusScreen> createState() =>
      _RelationshipStatusScreenState();
}

class _RelationshipStatusScreenState extends State<RelationshipStatusScreen> {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.pairData.addListener(_onPairChanged);
  }

  @override
  void dispose() {
    widget.pairData.removeListener(_onPairChanged);
    super.dispose();
  }

  void _onPairChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connection = widget.pairData.manager.activeConnection;
    if (connection == null) {
      return Scaffold(
        appBar: AppBar(title: Text(LocaleService.current.relationshipStatus)),
        body: Center(child: Text(LocaleService.current.noActiveConnection)),
      );
    }

    final currentStatus = connection.currentStatus;
    final t = context.appTheme;

    return Scaffold(
      backgroundColor: t.surfaceMuted,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          LocaleService.current.relationshipStatus,
          style: TextStyle(
            color: t.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: M3LoadingDots(color: Color(0xFFFF7E8B)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Current Status Card
                  _buildCurrentStatusCard(currentStatus),
                  const SizedBox(height: 24),

                  // Predefined Statuses
                  _buildSectionTitle(LocaleService.current.chooseAStatus),
                  const SizedBox(height: 12),
                  ...RelationshipStatus.predefinedStatuses.map(
                    (status) => _buildStatusTile(
                      status,
                      isSelected: currentStatus?.id == status.id,
                      onTap: () => _setStatus(status),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Custom Statuses
                  _buildSectionTitle(LocaleService.current.customStatuses),
                  const SizedBox(height: 12),
                  ...connection.customStatuses.map(
                    (status) => _buildStatusTile(
                      status,
                      isSelected: currentStatus?.id == status.id,
                      isCustom: true,
                      onTap: () => _setStatus(status),
                      onEdit: () => _editCustomStatus(status),
                      onDelete: () => _deleteCustomStatus(status),
                    ),
                  ),

                  const SizedBox(height: 12),
                  _buildAddCustomButton(),
                  const SizedBox(height: 24),

                  // Clear Status Button
                  if (currentStatus != null) _buildClearStatusButton(),
                ],
              ),
            ),
    );
  }

  Widget _buildCurrentStatusCard(RelationshipStatus? status) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.pink.shade100, Colors.purple.shade100],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            LocaleService.current.currentStatus,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          Text(status?.emoji ?? '—', style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 8),
          Text(
            status?.label ?? LocaleService.current.notSet,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    final t = context.appTheme;
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: t.textPrimary,
      ),
    );
  }

  Widget _buildStatusTile(
    RelationshipStatus status, {
    required bool isSelected,
    bool isCustom = false,
    VoidCallback? onTap,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
  }) {
    final t = context.appTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? Colors.pink.shade50 : t.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? Colors.pink.shade300 : t.divider,
          width: 2,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Text(status.emoji, style: const TextStyle(fontSize: 28)),
        title: Text(
          status.label,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            color: t.textPrimary,
          ),
        ),
        trailing: isCustom
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelected)
                    const Icon(Icons.check_circle, color: Colors.pink),
                  if (isSelected) const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: onEdit,
                    color: Colors.blue,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    onPressed: onDelete,
                    color: Colors.red,
                  ),
                ],
              )
            : isSelected
            ? const Icon(Icons.check_circle, color: Colors.pink)
            : null,
      ),
    );
  }

  Widget _buildAddCustomButton() {
    final t = context.appTheme;
    return OutlinedButton.icon(
      onPressed: _addCustomStatus,
      icon: const Icon(Icons.add),
      label: Text(LocaleService.current.addCustomStatus),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        side: BorderSide(color: t.divider, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildClearStatusButton() {
    final t = context.appTheme;
    return ElevatedButton(
      onPressed: _clearStatus,
      style: ElevatedButton.styleFrom(
        backgroundColor: t.surfaceMuted,
        foregroundColor: t.textPrimary,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        LocaleService.current.clearStatus,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _setStatus(RelationshipStatus status) async {
    setState(() => _loading = true);
    try {
      await widget.pairData.manager.activeConnection?.setStatus(status);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.statusSetTo(status.label)),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.failedSetStatus('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearStatus() async {
    setState(() => _loading = true);
    try {
      await widget.pairData.manager.activeConnection?.clearStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.statusCleared),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.failedClearStatus('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addCustomStatus() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _CustomStatusDialog(),
    );

    if (result != null && mounted) {
      setState(() => _loading = true);
      try {
        await widget.pairData.manager.activeConnection?.addCustomStatus(
          result['label']!,
          result['emoji']!,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.customStatusAdded),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.failedAddStatus('$e')),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _editCustomStatus(RelationshipStatus status) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _CustomStatusDialog(
        initialLabel: status.label,
        initialEmoji: status.emoji,
        isEdit: true,
      ),
    );

    if (result != null && mounted) {
      setState(() => _loading = true);
      try {
        await widget.pairData.manager.activeConnection?.updateCustomStatus(
          status.id,
          result['label']!,
          result['emoji']!,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.statusUpdated),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.failedUpdateStatus('$e')),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _deleteCustomStatus(RelationshipStatus status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(LocaleService.current.deleteStatus),
        content: Text(LocaleService.current.deleteStatusConfirm(status.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              LocaleService.current.delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _loading = true);
      try {
        await widget.pairData.manager.activeConnection?.deleteCustomStatus(
          status.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.statusDeleted),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.failedDeleteStatus('$e')),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }
}

// Dialog for adding/editing custom status
class _CustomStatusDialog extends StatefulWidget {
  final String initialLabel;
  final String initialEmoji;
  final bool isEdit;

  const _CustomStatusDialog({
    this.initialLabel = '',
    this.initialEmoji = '',
    this.isEdit = false,
  });

  @override
  State<_CustomStatusDialog> createState() => _CustomStatusDialogState();
}

class _CustomStatusDialogState extends State<_CustomStatusDialog> {
  late TextEditingController _labelController;
  late TextEditingController _emojiController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.initialLabel);
    _emojiController = TextEditingController(text: widget.initialEmoji);
  }

  @override
  void dispose() {
    _labelController.dispose();
    _emojiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isEdit
            ? LocaleService.current.editStatus
            : LocaleService.current.addCustomStatus,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _emojiController,
            decoration: InputDecoration(
              labelText: LocaleService.current.emojiLabel,
              hintText: LocaleService.current.emojiHint,
            ),
            maxLength: 2,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _labelController,
            decoration: InputDecoration(
              labelText: LocaleService.current.labelField,
              hintText: LocaleService.current.egLivingTogether,
            ),
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(LocaleService.current.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            final label = _labelController.text.trim();
            final emoji = _emojiController.text.trim();
            if (label.isNotEmpty) {
              Navigator.pop(context, {'label': label, 'emoji': emoji});
            }
          },
          child: Text(
            widget.isEdit
                ? LocaleService.current.update
                : LocaleService.current.add,
          ),
        ),
      ],
    );
  }
}
