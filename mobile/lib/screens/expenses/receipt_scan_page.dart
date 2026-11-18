import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../services/receipt_scanner.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

/// Lecture du ticket par le modèle : la photo s'affiche avec une animation de scan.
/// Renvoie la lecture (ReceiptScan) ; null si l'utilisateur annule ; [ReceiptScanPage.manual]
/// s'il préfère saisir la dépense à la main après un échec (la photo reste jointe).
class ReceiptScanPage extends StatefulWidget {
  const ReceiptScanPage({super.key, required this.image, required this.scanner});

  final Uint8List image;
  final ReceiptScanner scanner;

  /// Résultat « saisir à la main ».
  static const manual = ReceiptScan();

  @override
  State<ReceiptScanPage> createState() => _ReceiptScanPageState();
}

class _ReceiptScanPageState extends State<ReceiptScanPage> with SingleTickerProviderStateMixin {
  late final _beam = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  String? _error;
  var _limited = false;
  var _run = 0;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _beam.dispose();
    super.dispose();
  }

  /// Erreur affichée : l'animation s'arrête (pas de calcul inutile à l'écran).
  void _fail(String message) {
    _beam.stop();
    setState(() => _error = message);
  }

  Future<void> _scan() async {
    final run = ++_run;
    setState(() {
      _error = null;
      _limited = false;
    });
    _beam.repeat(reverse: true);
    try {
      final result = await widget.scanner.scan(widget.image);
      if (!mounted || run != _run) return;
      if (result.isEmpty) {
        _fail(tr('Aucune information trouvée sur cette photo. Est-ce bien un ticket de caisse ?'));
        return;
      }
      Navigator.pop(context, result);
    } on PlanLimitException catch (e) {
      if (mounted && run == _run) {
        _limited = true;
        _fail(e.message);
        _upgrade();
      }
    } on ReceiptScanException catch (e) {
      if (mounted && run == _run) _fail(e.message);
    } catch (_) {
      if (mounted && run == _run) _fail(tr('Le ticket n\'a pas pu être lu. Réessaie.'));
    }
  }

  /// Quota du mois atteint : propose l'offre supérieure.
  Future<void> _upgrade() => showUpgradeSheet(context, message: _error ?? '', feature: PlanFeature.scan);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scanning = _error == null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Scanner un reçu'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Stack(
                      children: [
                        Image.memory(widget.image, fit: BoxFit.contain),
                        if (scanning)
                          Positioned.fill(
                            child: AnimatedBuilder(
                              animation: _beam,
                              builder: (context, _) => CustomPaint(
                                painter: _BeamPainter(progress: _beam.value, color: colors.primary),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (scanning) ...[
                const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 14),
                Text(tr('Lecture du ticket…'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  tr('L\'assistant repère le total, la date, l\'enseigne et les articles.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Annuler'))),
              ] else ...[
                Icon(Icons.error_outline_rounded, color: colors.error, size: 32),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 16),
                if (_limited) ...[
                  FilledButton.icon(
                    onPressed: _upgrade,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    icon: const Icon(Icons.workspace_premium_rounded),
                    label: Text(tr('Passer à l\'offre supérieure')),
                  ),
                  const SizedBox(height: 8),
                ] else
                  FilledButton.icon(
                    onPressed: _scan,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(tr('Réessayer')),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, ReceiptScanPage.manual),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.edit_note_rounded),
                  label: Text(tr('Saisir à la main avec cette photo')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bande lumineuse qui balaie le ticket pendant la lecture.
class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;
    final rect = Rect.fromLTWH(0, y - 40, size.width, 80);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.progress != progress;
}
