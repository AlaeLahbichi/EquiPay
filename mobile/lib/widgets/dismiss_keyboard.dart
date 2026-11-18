import 'package:flutter/material.dart';

/// Dans toute l'app : toucher un endroit vide retire le focus du champ en cours et ferme le clavier.
/// Les champs, boutons et listes gardent leur geste : seul un toucher non utilisé ferme le clavier.
class DismissKeyboard extends StatelessWidget {
  const DismissKeyboard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}
