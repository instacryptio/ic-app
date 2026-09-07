import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../main.dart' show CustomTitlebarStyle, titlebarStyle;

class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({
    super.key,
    required this.title,
    this.leading,
  });

  final String title;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CustomTitlebarStyle>(
      valueListenable: titlebarStyle,
      builder: (context, style, _) {
        switch (style) {
          case CustomTitlebarStyle.clean:
            return _CleanTitleBar(title: title, leading: leading);
          case CustomTitlebarStyle.custom:
          case CustomTitlebarStyle.native:
          case CustomTitlebarStyle.defaultStyle:
            return _DefaultTitleBar(title: title, leading: leading);
        }
      },
    );
  }
}

class _CleanTitleBar extends StatelessWidget {
  const _CleanTitleBar({
    required this.title,
    this.leading,
  });

  final String title;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 36,
      color: theme.colorScheme.surface,
      child: Stack(
        children: [
          // Full-width drag area with truly centered title.
          DragToMoveArea(
            child: Center(
              child: Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Window controls positioned on the edges.
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            right: 4,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (Platform.isMacOS) const SizedBox(width: 70),
                if (leading != null) leading!,
                const Spacer(),
                // Traffic lights on the right for Linux and Windows.
                if (!Platform.isMacOS) ...[
                  _TrafficLight(
                    color: const Color(0xFFFFBD2E),
                    hoverColor: const Color(0xFFFFBD2E),
                    onPressed: () => windowManager.minimize(),
                    tooltip: 'Minimize',
                  ),
                  const SizedBox(width: 8),
                  _TrafficMaximizeLight(),
                  const SizedBox(width: 8),
                  _TrafficLight(
                    color: const Color(0xFFFF5F57),
                    hoverColor: const Color(0xFFFF5F57),
                    onPressed: () => windowManager.close(),
                    tooltip: 'Close',
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DefaultTitleBar extends StatelessWidget {
  const _DefaultTitleBar({
    required this.title,
    this.leading,
  });

  final String title;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 48,
      color: theme.colorScheme.surface,
      child: Stack(
        children: [
          // Full-width drag area with centered/left-aligned title.
          DragToMoveArea(
            child: Platform.isMacOS
                ? Center(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ),
          // Window controls positioned on the edges.
          Row(
            children: [
              if (Platform.isMacOS) const SizedBox(width: 70),
              if (leading != null) leading!,
              const Spacer(),
              // Window controls on Linux and Windows.
              if (Platform.isLinux || Platform.isWindows) ...[
                _WindowButton(
                  icon: Icons.minimize,
                  onPressed: () => windowManager.minimize(),
                  tooltip: 'Minimize',
                ),
                _MaximizeButton(),
                _WindowButton(
                  icon: Icons.close,
                  onPressed: () => windowManager.close(),
                  tooltip: 'Close',
                  isClose: true,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _TrafficLight extends StatefulWidget {
  const _TrafficLight({
    required this.color,
    required this.hoverColor,
    required this.onPressed,
    required this.tooltip,
  });

  final Color color;
  final Color hoverColor;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  State<_TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<_TrafficLight> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovering
                  ? widget.hoverColor
                  : widget.color.withValues(alpha: 0.8),
              border: Border.all(
                color: widget.color.withValues(alpha: 0.2),
                width: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrafficMaximizeLight extends StatefulWidget {
  @override
  State<_TrafficMaximizeLight> createState() => _TrafficMaximizeLightState();
}

class _TrafficMaximizeLightState extends State<_TrafficMaximizeLight>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _updateMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    return _TrafficLight(
      color: const Color(0xFF28C840),
      hoverColor: const Color(0xFF28C840),
      onPressed: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      tooltip: _isMaximized ? 'Restore' : 'Maximize',
    );
  }
}

class _MaximizeButton extends StatefulWidget {
  @override
  State<_MaximizeButton> createState() => _MaximizeButtonState();
}

class _MaximizeButtonState extends State<_MaximizeButton> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _updateMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    return _WindowButton(
      icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
      onPressed: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      tooltip: _isMaximized ? 'Restore' : 'Maximize',
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: isClose
              ? Colors.red.withValues(alpha: 0.8)
              : theme.colorScheme.onSurface.withValues(alpha: 0.1),
          child: SizedBox(
            width: 46,
            height: 48,
            child: Icon(
              icon,
              size: 18,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
