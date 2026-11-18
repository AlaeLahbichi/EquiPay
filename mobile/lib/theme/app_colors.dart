import 'package:flutter/material.dart';

/// Palette « Lagon » de l'application.
class AppColors {
  AppColors._();

  // Couleurs principales
  static const primary = Color(0xFF0D9488);
  static const primaryDark = Color(0xFF2DD4BF);
  static const accent = Color(0xFFF97316);

  // Fonds et textes (mode clair)
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);
  static const text = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);

  // Fonds (mode sombre)
  static const backgroundDark = Color(0xFF0B1220);
  static const surfaceDark = Color(0xFF111827);

  // Soldes
  static const positive = Color(0xFF16A34A);
  static const negative = Color(0xFFDC2626);
  static const neutral = Color(0xFF64748B);

  // Avertissements (champ à vérifier)
  static const warning = Color(0xFFD97706);

  // Types d'activité
  static const voyage = Color(0xFF0D9488);
  static const sortie = Color(0xFF8B5CF6);
  static const quotidien = Color(0xFF3B82F6);
  static const credit = Color(0xFFF59E0B);
}
