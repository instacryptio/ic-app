import 'package:flutter/material.dart';

/// showTopDrawer presents [builder]'s widget as a full-width drawer that
/// slides down from the top of the window (the inverse of a modal bottom
/// sheet). Dismiss by tapping outside, swiping the bottom grab handle up,
/// or Navigator.pop. Content is capped at 80% of the window height and
/// should carry its own SafeArea — the drawer sits under the status bar on
/// mobile.
Future<T?> showTopDrawer<T>(BuildContext context, {required WidgetBuilder builder}) {
  final theme = Theme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, __) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.8,
        ),
        child: SizedBox(
          width: double.infinity,
          child: _TopDrawerShell(
            color: theme.bottomSheetTheme.backgroundColor ??
                theme.colorScheme.surfaceContainerLow,
            child: builder(ctx),
          ),
        ),
      ),
    ),
    // ClipRect bounds the slide to the dialog area: without it the drawer
    // overdraws whatever sits above the Navigator while animating — on
    // desktop that's the custom title bar (it would "roll over" the bar and
    // then settle beneath it). Clipped, it unrolls from under the bar.
    transitionBuilder: (ctx, animation, _, child) => ClipRect(
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

/// _TopDrawerShell renders the drawer surface plus the bottom grab handle:
/// the mirror of a bottom sheet's top handle. Swiping the handle upward
/// drags the whole drawer with the finger and dismisses past ~25% of its
/// height (or on an upward fling); shorter drags spring back. The drag
/// surface is ONLY the handle strip — the drawer bodies scroll internally.
class _TopDrawerShell extends StatefulWidget {
  const _TopDrawerShell({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_TopDrawerShell> createState() => _TopDrawerShellState();
}

class _TopDrawerShellState extends State<_TopDrawerShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle;
  double _dragOffset = 0; // ≤ 0: how far the drawer is dragged upward

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    )..addListener(() {
        setState(() {
          // Animate the offset back toward zero (spring-back).
          _dragOffset = _dragStart * (1 - Curves.easeOut.transform(_settle.value));
        });
      });
  }

  double _dragStart = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _dragOffset = (_dragOffset + d.delta.dy).clamp(-10000.0, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final height = context.size?.height ?? 0;
    final flungUp = d.velocity.pixelsPerSecond.dy < -700;
    final draggedFar = height > 0 && -_dragOffset > height * 0.25;
    if (flungUp || draggedFar) {
      Navigator.of(context).pop();
      return;
    }
    _dragStart = _dragOffset;
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Transform.translate(
      offset: Offset(0, _dragOffset),
      child: Material(
        clipBehavior: Clip.antiAlias,
        color: widget.color,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: widget.child),
            // Bottom grab handle — swipe up (or tap) to close.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              child: SizedBox(
                width: double.infinity,
                height: 24,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
