import 'package:flutter/material.dart';

import '../../services/update/update_controller.dart';
import '../dialogs/update_dialog.dart';

/// Invisible wrapper that kicks off the silent startup update check and
/// presents [UpdateDialog] when a newer release is found. Mount it once,
/// under the [MaterialApp] Navigator (it calls [showDialog]) — in this app
/// that is around the root Scaffold in `main_screen.dart`'s `home:`.
class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key, required this.controller, required this.child});

  final UpdateController controller;
  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  bool _dialogVisible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onUpdateStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.checkSilently();
    });
  }

  @override
  void didUpdateWidget(UpdateGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onUpdateStateChanged);
      widget.controller.addListener(_onUpdateStateChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onUpdateStateChanged);
    super.dispose();
  }

  void _onUpdateStateChanged() {
    if (!mounted || _dialogVisible) return;
    if (widget.controller.availableUpdate == null) return;
    _dialogVisible = true;
    showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(controller: widget.controller),
    ).whenComplete(() => _dialogVisible = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
