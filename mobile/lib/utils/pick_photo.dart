import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../l10n/i18n.dart';

/// Demande une photo (galerie ou appareil photo), réduite et compressée en JPEG.
/// Renvoie null si l'utilisateur annule ou si l'accès aux photos est refusé.
Future<Uint8List?> pickPhoto(BuildContext context, {required String title, double maxSize = 1600}) async {
  final messenger = ScaffoldMessenger.of(context);
  final source = await _askSource(context, title: title);
  if (source == null) return null;
  try {
    final file = await ImagePicker().pickImage(source: source, maxWidth: maxSize, maxHeight: maxSize, imageQuality: 80);
    return file == null ? null : await file.readAsBytes();
  } catch (_) {
    _denied(messenger);
    return null;
  }
}

/// Comme [pickPhoto], mais permet de choisir plusieurs photos d'un coup dans la galerie
/// (au plus [limit]). L'appareil photo en renvoie une seule. Liste vide si l'utilisateur annule.
Future<List<Uint8List>> pickPhotos(
  BuildContext context, {
  required String title,
  int limit = 20,
  double maxSize = 1600,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final source = await _askSource(context, title: title, galleryLabel: tr('Choisir dans la galerie (plusieurs possibles)'));
  if (source == null) return [];
  try {
    final picker = ImagePicker();
    final files = source == ImageSource.camera
        ? [?await picker.pickImage(source: source, maxWidth: maxSize, maxHeight: maxSize, imageQuality: 80)]
        : await picker.pickMultiImage(maxWidth: maxSize, maxHeight: maxSize, imageQuality: 80, limit: limit);
    return [for (final f in files.take(limit)) await f.readAsBytes()];
  } catch (_) {
    _denied(messenger);
    return [];
  }
}

void _denied(ScaffoldMessengerState messenger) => messenger.showSnackBar(
  SnackBar(content: Text(tr('Impossible d\'accéder aux photos. Vérifie les autorisations.'))),
);

Future<ImageSource?> _askSource(
  BuildContext context, {
  required String title,
  String? galleryLabel,
}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(galleryLabel ?? tr('Choisir dans la galerie')),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Prendre une photo')),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
