import 'package:flutter/material.dart';

import '../models/user_profile.dart';

/// Photo de profil ronde : photo de l'utilisateur, sinon l'avatar par défaut.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, this.user, this.size = 120});

  static const defaultImage = AssetImage('assets/images/default_avatar.png');

  final UserProfile? user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = user?.avatarUrl;
    const fallback = Image(image: defaultImage, fit: BoxFit.cover);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: ClipOval(
        child: url != null && url.isNotEmpty
            ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback)
            : fallback,
      ),
    );
  }
}
