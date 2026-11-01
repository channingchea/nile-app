import 'overlay_layout.dart';
import 'studio_graphics.dart';
import 'studio_layouts.dart';

/// Ready-made layouts (docs/plans/studio-layouts.md, phase 6). "New from
/// template" saves the graphics a template needs into the host's library
/// (reusing an identical one already there) and a layout that points at them,
/// sized to the show's camera count. Graphics follow the brand kit like any
/// other library graphic.
class LayoutTemplate {
  const LayoutTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.graphics,
    required this.build,
  });

  /// Stored in `studio_layouts.template`.
  final String id;
  final String name;
  final String description;

  /// Library graphics it needs. Each [StudioGraphic.id] is a local key that
  /// [build] refers to.
  final List<StudioGraphic> graphics;

  /// The layout for [cameras] cameras; [ref] turns a graphic's key into its
  /// library id.
  final StudioLayout Function(String Function(String key) ref, int cameras)
  build;
}

/// The four templates. [logoPath] is the brand kit's logo (a studio-graphics
/// path); without one, Main show has no logo bug. [hostName] fills the lower
/// third.
List<LayoutTemplate> layoutTemplates({
  String? logoPath,
  String hostName = 'Your name',
}) {
  final hasLogo = logoPath != null && logoPath.isNotEmpty;
  List<LayoutCamera> every(int n, LayoutCamera Function(int i) cam) => [
    for (var i = 0; i < n; i++) cam(i),
  ];
  return [
    LayoutTemplate(
      id: 'starting_soon',
      name: 'Starting soon',
      description: 'Full-screen slate counting down to the show’s start.',
      graphics: const [
        StudioGraphic(
          id: 'slate',
          kind: GraphicKind.slate,
          name: 'Starting soon',
          payload: {
            'title': 'Starting soon',
            'countdown': {'mode': 'showStart'},
          },
        ),
      ],
      build: (ref, n) => StudioLayout(
        name: 'Starting soon',
        template: 'starting_soon',
        cameras: every(
          n,
          (_) => LayoutCamera(items: [LayoutItem.graphic(ref('slate'))]),
        ),
        defaultAngle: const AngleRef.camera(1),
      ),
    ),
    LayoutTemplate(
      id: 'be_right_back',
      name: 'Be right back',
      description: 'A slate on Camera 1; every other camera off air.',
      graphics: const [
        StudioGraphic(
          id: 'slate',
          kind: GraphicKind.slate,
          name: 'Be right back',
          payload: {'title': 'Be right back'},
        ),
      ],
      build: (ref, n) => StudioLayout(
        name: 'Be right back',
        template: 'be_right_back',
        cameras: every(
          n,
          (i) => LayoutCamera(
            items: [LayoutItem.graphic(ref('slate'))],
            onAir: i == 0,
          ),
        ),
        defaultAngle: const AngleRef.camera(1),
      ),
    ),
    LayoutTemplate(
      id: 'ending',
      name: 'Ending',
      description: 'A thank-you slate with a QR code to your profile.',
      graphics: const [
        StudioGraphic(
          id: 'slate',
          kind: GraphicKind.slate,
          name: 'Thanks for watching',
          payload: {
            'title': 'Thank you for watching',
            'subtitle': 'Follow for the next show.',
          },
        ),
        StudioGraphic(
          id: 'qr',
          kind: GraphicKind.qr,
          name: 'Follow me (QR)',
          payload: {
            'source': 'profile',
            'corner': 'br',
            'size': 'l',
            'caption': 'Follow me',
          },
        ),
      ],
      build: (ref, n) => StudioLayout(
        name: 'Ending',
        template: 'ending',
        cameras: every(
          n,
          (_) => LayoutCamera(
            // Front to back: the QR code sits over the slate.
            items: [
              LayoutItem.graphic(ref('qr')),
              LayoutItem.graphic(ref('slate')),
            ],
          ),
        ),
      ),
    ),
    LayoutTemplate(
      id: 'main_show',
      name: 'Main show',
      description: hasLogo
          ? 'Your logo on every camera and a lower third on Camera 1.'
          : 'A lower third on Camera 1. Add a logo to your brand kit for a '
                'logo bug too.',
      graphics: [
        if (hasLogo)
          StudioGraphic(
            id: 'logo',
            kind: GraphicKind.logo,
            name: 'Logo',
            payload: {'imagePath': logoPath, 'corner': 'tr', 'size': 's'},
          ),
        StudioGraphic(
          id: 'lt',
          kind: GraphicKind.lowerThird,
          name: hostName,
          payload: {'title': hostName},
        ),
      ],
      build: (ref, n) => StudioLayout(
        name: 'Main show',
        template: 'main_show',
        cameras: every(
          n,
          (i) => LayoutCamera(
            items: [
              if (i == 0) LayoutItem.graphic(ref('lt'), spot: LayoutSpot.bl),
              if (hasLogo) LayoutItem.graphic(ref('logo')),
            ],
          ),
        ),
        defaultAngle: const AngleRef.camera(1),
      ),
    ),
  ];
}
