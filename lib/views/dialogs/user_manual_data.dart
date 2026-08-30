import 'package:flutter/material.dart';
import '../../models/manual_topic.dart';

/// Centralized repository for all user manual guides and documentation in SnipSnap.
class UserManualData {
  UserManualData._();

  static const List<ManualTopic> topics = [
    ManualTopic(
      id: 'getting_started',
      title: 'Getting Started',
      subtitle: 'Overview, core workflow, and canvas navigation',
      icon: Icons.rocket_launch_rounded,
      badge: 'Start Here',
      keywords: ['overview', 'quickstart', 'zoom', 'pan', 'open', 'paste', 'clipboard', 'workflow'],
      sections: [
        ManualSection(
          title: 'Welcome to SnipSnap',
          description:
              'SnipSnap is a high-performance desktop screenshot capture, vector annotation, and image editing suite built with Flutter and Drift SQLite. It handles high-DPI Retina captures, non-destructive vector annotations, on-device OCR, canvas framing, and floating screen pins.',
          tags: ['Overview', 'Desktop'],
        ),
        ManualSection(
          title: 'Core 3-Step Workflow',
          description:
              'SnipSnap makes capturing and sharing annotated visuals effortless in three simple steps:',
          steps: [
            'Capture or Import: Press Cmd+Shift+1 (or click Area Snip) or open an existing image file from your disk.',
            'Annotate & Frame: Apply arrows, step markers, text callouts, shapes, blur sensitive data, or add gradient framing.',
            'Copy or Export: Press Cmd+C to copy the annotated composite directly to your clipboard, or Cmd+S to save as PNG/JPEG.',
          ],
          shortcuts: ['Cmd+Shift+1', 'Cmd+C', 'Cmd+S'],
        ),
        ManualSection(
          title: 'Canvas Zoom & Panning',
          description:
              'Work comfortably with high-resolution captures using precision navigation controls:',
          steps: [
            'Zoom In / Out: Scroll with your mouse wheel or use trackpad pinch gestures. The zoom scale ranges from 20% up to 400%.',
            'Pan Canvas: Hold Spacebar and drag with your mouse, or drag with the middle mouse button to move across the image.',
            'Reset Zoom: Click the zoom percentage indicator in the top header bar to quickly snap back to 100% (the fit-to-window baseline).',
          ],
          tip: 'When working on multi-megapixel screenshots, zooming in helps you place pixel-perfect arrows and text callouts.',
        ),
        ManualSection(
          title: 'Importing Images & Clipboard',
          description:
              'You can bring existing graphics into SnipSnap at any time:',
          steps: [
            'File Picker: Click "Open Image" in the top bar or press Cmd+O to select any PNG, JPEG, WebP, or BMP file.',
            'Gallery: Reopen any earlier capture from the Screenshots strip along the bottom of the window.',
          ],
          shortcuts: ['Cmd+O'],
        ),
      ],
    ),
    ManualTopic(
      id: 'capture_modes',
      title: 'Screen Capture & DPI',
      subtitle: 'Area capture, fullscreen, timer, and high-DPI scaling',
      icon: Icons.camera_alt_rounded,
      keywords: ['snip', 'capture', 'fullscreen', 'area', 'region', 'timer', 'retina', 'dpi', 'display', 'monitor'],
      sections: [
        ManualSection(
          title: 'Interactive Area Snip',
          description:
              'Click and drag a marquee rectangle across any region of your screen. The interactive capture overlay dims the desktop with crosshairs and displays real-time pixel dimensions.',
          steps: [
            'Click the "Area Snip" button in the header bar or press your global capture hotkey.',
            'Click and drag the cursor across the target region on your screen.',
            'Release the mouse to instantly crop and import the captured area into the SnipSnap editor.',
            'Press ESC at any time to cancel the capture.',
          ],
          shortcuts: ['Cmd+Shift+1', 'ESC'],
        ),
        ManualSection(
          title: 'Full Screen Snip',
          description:
              'Capture your entire primary desktop display in a single click without needing to drag a marquee.',
          shortcuts: ['Cmd+Shift+2'],
        ),
        ManualSection(
          title: '3-Second Timer Snip',
          description:
              'Trigger a delayed 3-second countdown capture. This gives you time to open dropdown menus, hover tooltips, modal dialogs, or right-click context menus before the screenshot fires.',
          tip: 'Use Timer Snip whenever capturing transient UI states that disappear when you click outside the application.',
          shortcuts: ['Cmd+Shift+6'],
        ),
        ManualSection(
          title: 'Retina & High-DPI Display Awareness',
          description:
              'SnipSnap automatically samples screen buffers at native device pixel ratios (2.0x on macOS Retina, 1.25x-2.5x on Windows). Vector coordinates scale precisely so annotations render crisp on ultra-high-resolution displays.',
          tags: ['High-DPI', 'Retina 2x/3x'],
        ),
      ],
    ),
    ManualTopic(
      id: 'annotation_tools',
      title: 'Annotation & Drawing Tools',
      subtitle: 'Vector shapes, arrows, step markers, blur, and highlighters',
      icon: Icons.draw_rounded,
      badge: 'Core Tools',
      keywords: ['arrow', 'shape', 'rectangle', 'oval', 'step', 'marker', 'number', 'badge', 'text', 'blur', 'pixelate', 'highlighter', 'pen', 'ruler', 'fill'],
      sections: [
        ManualSection(
          title: 'Vector Arrows & Lines',
          description:
              'Draw sleek directional arrows to highlight user interface elements or point out details. Arrowheads scale proportionally with your chosen stroke thickness.',
          steps: [
            'Select the Arrow tool from the left toolbar (shortcut: A).',
            'Click at the starting point and drag toward the target destination.',
            'Adjust stroke width and color from the Tool Properties panel on the right.',
          ],
          shortcuts: ['A', 'L'],
        ),
        ManualSection(
          title: 'Rectangles & Ovals',
          description:
              'Highlight regions with geometric shapes. Supports customizable border thickness, rounded corners, and solid or translucent fill colors.',
          shortcuts: ['R', 'U'],
        ),
        ManualSection(
          title: 'Step Counter Badges (1, 2, 3...)',
          description:
              'Create sequential numbered circle badges to write step-by-step guides, user manuals, and bug reproduction walkthroughs. Badges auto-increment on each click.',
          steps: [
            'Select the Step Marker tool from the toolbar (shortcut: N).',
            'Click on each UI element in the sequence you want the user to follow.',
            'Numbers automatically increment (1, 2, 3, 4...).',
            'Re-order or adjust badge colors in the Properties inspector.',
          ],
          tip: 'Step badges are indispensable for creating clear documentation and bug tickets in Jira, GitHub, or Linear.',
          shortcuts: ['N'],
        ),
        ManualSection(
          title: 'Text Callouts',
          description:
              'Add clear vector typography anywhere on the canvas. Customize font size, weight, letter spacing, text color, and optional background pill styling for maximum legibility on busy images.',
          shortcuts: ['T'],
        ),
        ManualSection(
          title: 'Freehand Pen & Highlighter',
          description:
              'Sketch custom drawings with the Pen tool (smooth Bezier curve fitting) or highlight important text passages with the translucent Highlighter tool.',
          shortcuts: ['P', 'H'],
        ),
        ManualSection(
          title: 'Blur & Pixelate Redaction',
          description:
              'Redact sensitive information like passwords, API tokens, email addresses, and credit card numbers before sharing screenshots.',
          steps: [
            'Select the Blur tool (shortcut: B).',
            'Drag a rectangle over the sensitive text or image area.',
            'Choose between smooth Gaussian Blur or 8-bit Pixelate in the properties panel.',
          ],
          shortcuts: ['B'],
        ),
        ManualSection(
          title: 'Pixel Ruler & Measurement',
          description:
              'Measure exact pixel distances, dimensions, and padding between elements on your screenshot.',
          shortcuts: ['M'],
        ),
        ManualSection(
          title: 'Color Bucket Fill',
          description:
              'Quickly fill vector shapes or background areas with your active swatch color.',
          shortcuts: ['G'],
        ),
      ],
    ),
    ManualTopic(
      id: 'ocr_text',
      title: 'OCR Text Recognition',
      subtitle: 'Extract, edit, and copy text directly from screenshots',
      icon: Icons.document_scanner_rounded,
      badge: 'AI / OCR',
      keywords: ['ocr', 'text', 'extract', 'recognition', 'copy', 'scan', 'read', 'clipboard'],
      sections: [
        ManualSection(
          title: 'Extracting Text with the OCR Tool',
          description:
              'Extract unselectable text from images, videos, error dialogues, terminal windows, or PDFs without retyping a single character.',
          steps: [
            'Click the OCR Tool icon in the toolbar or press "E".',
            'Drag a selection box over the text area in your screenshot.',
            'SnipSnap runs on-device OCR text recognition in milliseconds.',
            'The extracted text pops up in the OCR Result panel for quick review.',
          ],
          shortcuts: ['E'],
        ),
        ManualSection(
          title: 'OCR Result Panel & Copying',
          description:
              'Once extracted, you can edit the text directly, remove line breaks, or click "Copy to Clipboard" to paste the text into your code editor or notes.',
          tip: 'OCR runs entirely locally on your device for complete privacy and instant performance.',
        ),
      ],
    ),
    ManualTopic(
      id: 'canvas_framing',
      title: 'Canvas Framing & Backgrounds',
      subtitle: 'Padding, drop shadows, rounded corners, and gradients',
      icon: Icons.wallpaper_rounded,
      keywords: ['frame', 'framing', 'padding', 'margin', 'shadow', 'radius', 'rounded', 'gradient', 'background'],
      sections: [
        ManualSection(
          title: 'Canvas Margins & Padding',
          description:
              'Give your screenshots a polished studio appearance by adding customizable canvas padding around the image.',
          steps: [
            'Open the Tool Properties panel on the right with the tune icon in the header bar.',
            'Adjust the Canvas Padding slider to add outer margin.',
            'Select an aspect ratio preset (16:9, 4:3, 1:1) or keep custom dimensions.',
          ],
        ),
        ManualSection(
          title: 'Drop Shadows & Corner Radii',
          description:
              'Add modern depth to your screenshots with configurable drop shadow blur, elevation, and smooth corner rounding.',
          tip: 'Rounded corners and soft drop shadows make screenshots look gorgeous when embedding in documentation or tweets.',
        ),
        ManualSection(
          title: 'Background Fill Styles',
          description:
              'Choose from sleek modern gradient presets (Midnight, Sunset, Oceanic, Titanium), flat solid colors, or transparent alpha backgrounds.',
        ),
      ],
    ),
    ManualTopic(
      id: 'screen_pinning',
      title: 'Screen Pinning',
      subtitle: 'Always-on-top floating reference windows',
      icon: Icons.push_pin_rounded,
      keywords: ['pin', 'pinning', 'floating', 'overlay', 'reference', 'window', 'topmost'],
      sections: [
        ManualSection(
          title: 'What is Screen Pinning?',
          description:
              'Screen Pinning lets you float any capture as a borderless, always-on-top window. It stays visible over your IDE, browser, or design tools so you can reference code snippets, designs, or specs without window switching.',
        ),
        ManualSection(
          title: 'How to Pin a Capture',
          description:
              'Click the Pin icon in the top header bar. A lightweight floating window will immediately spawn with the active capture.',
          steps: [
            'Click the Pin icon in the header bar.',
            'Drag the floating window to any monitor or position.',
            'Resize using the corner handles.',
            'Double-click or press ESC to close the pinned window.',
          ],
          tip: 'You can spawn multiple pinned windows simultaneously to compare before-and-after UI designs side-by-side.',
        ),
      ],
    ),
    ManualTopic(
      id: 'shortcuts_guide',
      title: 'Keyboard Shortcuts',
      subtitle: 'Global capture hotkeys and canvas editing shortcuts',
      icon: Icons.keyboard_rounded,
      badge: 'Cheat Sheet',
      keywords: ['shortcuts', 'hotkeys', 'keybindings', 'commands', 'undo', 'redo', 'copy', 'save'],
      sections: [
        ManualSection(
          title: 'Global Capture Hotkeys',
          description:
              'Trigger captures system-wide even when SnipSnap is running in the background:',
          steps: [
            'Area Snip: Cmd + Shift + 1 (macOS) / Ctrl + Shift + 1 (Windows)',
            'Full Screen Snip: Cmd + Shift + 2 (macOS) / Ctrl + Shift + 2 (Windows)',
            '3s Timer Snip: Cmd + Shift + 6 (macOS) / Ctrl + Shift + 6 (Windows)',
          ],
          shortcuts: ['Cmd+Shift+1', 'Cmd+Shift+2', 'Cmd+Shift+6'],
        ),
        ManualSection(
          title: 'Canvas Editing & History',
          description:
              'Fast keyboard actions for editing and export:',
          steps: [
            'Undo Last Annotation: Cmd + Z / Ctrl + Z',
            'Redo Last Annotation: Cmd + Shift + Z / Ctrl + Shift + Z',
            'Copy to Clipboard: Cmd + C / Ctrl + C',
            'Save Image As: Cmd + S / Ctrl + S',
            'Toggle Gallery Sidebar: Cmd + H / Ctrl + H',
            'Flatten Annotations into Bitmap: Cmd + Shift + F / Ctrl + Shift + F',
            'Clear All Annotations: Cmd + Shift + K / Ctrl + Shift + K',
            'User Guide & Help: F1 or Cmd + ?',
          ],
          shortcuts: ['Cmd+Z', 'Cmd+Shift+Z', 'Cmd+C', 'Cmd+S', 'Cmd+H', 'F1'],
        ),
        ManualSection(
          title: 'Customizing Your Shortcuts',
          description:
              'Open the "Keyboard Shortcuts…" settings dialog from the top overflow menu to record custom key chords for any action.',
        ),
      ],
    ),
    ManualTopic(
      id: 'troubleshooting',
      title: 'Permissions & System Setup',
      subtitle: 'macOS permissions, Windows display scaling, and SQLite',
      icon: Icons.settings_suggest_rounded,
      keywords: ['permissions', 'macos', 'accessibility', 'screen recording', 'windows', 'sqlite', 'database', 'troubleshooting'],
      sections: [
        ManualSection(
          title: 'macOS Screen Recording Permissions',
          description:
              'macOS requires explicit user consent for applications to capture screen pixels. If captures appear blank or transparent:',
          steps: [
            'Open macOS System Settings.',
            'Navigate to Privacy & Security > Screen Recording.',
            'Enable the toggle next to SnipSnap.',
            'Restart SnipSnap if prompted by the operating system.',
          ],
          tip: 'This is a macOS security sandbox requirement for all screen capture utilities.',
        ),
        ManualSection(
          title: 'macOS Accessibility Permissions',
          description:
              'To enable global capture hotkeys while working in other apps, enable SnipSnap under System Settings > Privacy & Security > Accessibility.',
        ),
        ManualSection(
          title: 'Local Drift SQLite Database',
          description:
              'All screenshots, vector annotations, and preferences are stored 100% locally on your computer in an encrypted/indexed SQLite database. No screenshots or OCR texts are ever sent to remote cloud servers.',
          tags: ['Privacy First', '100% Local'],
        ),
        ManualSection(
          title: 'Software Updates',
          description:
              'SnipSnap automatically checks GitHub Releases for new updates. You can check manually at any time via the update button in the header bar or About dialog.',
        ),
      ],
    ),
  ];
}
