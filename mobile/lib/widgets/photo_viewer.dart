import 'package:flutter/material.dart';

import '../services/activity_repository.dart';
import '../l10n/i18n.dart';

/// Une image affichable en plein écran.
class ViewerPhoto {
  const ViewerPhoto({required this.image, required this.heroTag, this.caption, this.canDelete = false});

  final ImageProvider image;
  final Object heroTag;
  final String? caption;
  final bool canDelete;
}

/// Action affichée en bas de la visionneuse (ex. « Changer la photo »).
class ViewerAction {
  const ViewerAction({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;

  /// Appelée après la fermeture de la visionneuse.
  final VoidCallback onPressed;
}

/// Ouvre une ou plusieurs photos en plein écran : zoom avec deux doigts, glisser pour changer.
Future<void> openPhotoViewer(
  BuildContext context, {
  required List<ViewerPhoto> photos,
  int initialIndex = 0,
  Future<void> Function(int index)? onDelete,
  ViewerAction? action,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) =>
          _PhotoViewerPage(photos: photos, initialIndex: initialIndex, onDelete: onDelete, action: action),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _PhotoViewerPage extends StatefulWidget {
  const _PhotoViewerPage({required this.photos, required this.initialIndex, this.onDelete, this.action});

  final List<ViewerPhoto> photos;
  final int initialIndex;
  final Future<void> Function(int index)? onDelete;
  final ViewerAction? action;

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  var _deleting = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Supprimer cette photo ?')),
        content: Text(tr('Elle sera retirée pour tous les membres de l\'activité.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(tr('Supprimer')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.onDelete!(_index);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    final many = widget.photos.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black38,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          tooltip: tr('Fermer'),
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: many ? Text('${_index + 1} / ${widget.photos.length}') : null,
        actions: [
          if (photo.canDelete && widget.onDelete != null)
            _deleting
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                  )
                : IconButton(
                    tooltip: tr('Supprimer la photo'),
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _delete,
                  ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _ZoomablePhoto(photo: widget.photos[i]),
          ),
          if (photo.caption != null || widget.action != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (photo.caption != null)
                        Text(
                          photo.caption!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      if (widget.action case final action?) ...[
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            Navigator.pop(context);
                            action.onPressed();
                          },
                          icon: Icon(action.icon),
                          label: Text(action.label),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ZoomablePhoto extends StatelessWidget {
  const _ZoomablePhoto({required this.photo});

  final ViewerPhoto photo;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: Hero(
          tag: photo.heroTag,
          child: Image(
            image: photo.image,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : const Center(child: CircularProgressIndicator(color: Colors.white)),
            // Réduit si besoin : pendant l'animation Hero, la zone peut être minuscule
            errorBuilder: (_, _, _) => FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                  SizedBox(height: 8),
                  Text(tr('Photo indisponible'), style: TextStyle(color: Colors.white54)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
