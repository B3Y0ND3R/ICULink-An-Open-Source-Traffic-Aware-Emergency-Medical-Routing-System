import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../models/booking_model.dart';
import '../services/firebase_service.dart';
import '../theme/app_theme.dart';

/// Shows a driver's past dispatches (all statuses), newest first.
class DriverHistoryScreen extends StatefulWidget {
  final String driverUid;
  const DriverHistoryScreen({super.key, required this.driverUid});

  @override
  State<DriverHistoryScreen> createState() => _DriverHistoryScreenState();
}

class _DriverHistoryScreenState extends State<DriverHistoryScreen> {
  List<BookingModel>? _bookings;
  StreamSubscription<List<BookingModel>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseService.instance
        .streamBookingsForDriver(widget.driverUid)
        .listen((bookings) {
      if (!mounted) return;
      setState(() => _bookings = bookings);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookings = _bookings;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Booking History',
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: bookings == null
                    ? const Center(child: CircularProgressIndicator())
                    : bookings.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            itemCount: bookings.length,
                            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (_, i) => _HistoryTile(booking: bookings[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history_rounded, color: AppColors.textTertiary, size: 40),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No dispatches yet',
            style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final BookingModel booking;
  const _HistoryTile({required this.booking});

  Color get _statusColor {
    switch (booking.status) {
      case BookingStatus.enRoute:
        return AppColors.accent;
      case BookingStatus.arrived:
        return AppColors.success;
      case BookingStatus.cancelled:
        return AppColors.textTertiary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalName =
        booking.targetHospitalName.isNotEmpty ? booking.targetHospitalName : 'Unknown hospital';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.sm + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hospitalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('MMM d, y • h:mm a').format(booking.createdAt),
                  style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs + 2, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              booking.status.label,
              style: GoogleFonts.inter(
                color: _statusColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
