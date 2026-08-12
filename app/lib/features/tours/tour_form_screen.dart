import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/models/enums.dart';
import '../../core/models/models.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Create or edit a tour, including its per-day plan.
///
/// The day rows are generated from the date range and stay editable, which is the
/// "Tour with optional per-day sub-plans" model: the tour is the container, each day
/// carries its own intent, and a pure travel day is a first-class thing rather than a
/// day with no visits.
class TourFormScreen extends ConsumerStatefulWidget {
  const TourFormScreen({super.key, this.tourId});

  final String? tourId;

  @override
  ConsumerState<TourFormScreen> createState() => _TourFormScreenState();
}

class _TourFormScreenState extends ConsumerState<TourFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  final _title = TextEditingController();
  final _purpose = TextEditingController();
  final _destination = TextEditingController();

  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();
  List<TourDay> _days = [];

  bool _busy = false;
  bool _loaded = false;
  Map<String, String> _fieldErrors = {};
  String? _existingId;
  TourStatus _status = TourStatus.planned;

  @override
  void initState() {
    super.initState();
    _start = _dateOnly(DateTime.now());
    _end = _start;
    _rebuildDays();
    if (widget.tourId != null) {
      _load();
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _purpose.dispose();
    _destination.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tour = await ref.read(apiClientProvider).tour(widget.tourId!);
      if (!mounted) return;
      setState(() {
        _existingId = tour.id;
        _title.text = tour.title;
        _purpose.text = tour.purpose ?? '';
        _destination.text = tour.destinationCity ?? '';
        _start = tour.plannedStartDate;
        _end = tour.plannedEndDate;
        _days = List.of(tour.days);
        _status = tour.status;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) {
        showApiError(context, e);
        setState(() => _loaded = true);
      }
    }
  }

  /// Regenerates day rows for the date range, preserving what the rep already entered
  /// for dates that survive the change.
  void _rebuildDays() {
    final existing = {for (final day in _days) _dateKey(day.planDate): day};
    final rebuilt = <TourDay>[];

    var seq = 1;
    for (var date = _start; !date.isAfter(_end); date = date.add(const Duration(days: 1))) {
      final key = _dateKey(date);
      final previous = existing[key];

      rebuilt.add(previous != null
          ? TourDay(
              id: previous.id,
              tourId: previous.tourId,
              planDate: date,
              daySeq: seq,
              activityType: previous.activityType,
              fromCity: previous.fromCity,
              toCity: previous.toCity,
              plannedTravelMode: previous.plannedTravelMode,
              overnightCity: previous.overnightCity,
              notes: previous.notes,
            )
          : TourDay(
              id: _uuid.v4(),
              tourId: _existingId ?? '',
              planDate: date,
              daySeq: seq,
              activityType: DayActivity.visits,
            ));
      seq++;
    }
    _days = rebuilt;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _fieldErrors = {};
    });

    final tour = Tour(
      id: _existingId ?? _uuid.v4(),
      title: _title.text.trim(),
      purpose: _purpose.text.trim().isEmpty ? null : _purpose.text.trim(),
      destinationCity: _destination.text.trim().isEmpty ? null : _destination.text.trim(),
      plannedStartDate: _start,
      plannedEndDate: _end,
      status: _status,
      days: _days,
    );

    try {
      await ref.read(apiClientProvider).saveTour(tour);
      bumpRefreshFrom(ref);
      if (!mounted) return;
      showSuccess(context, _existingId == null ? 'Tour created' : 'Tour updated');
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _fieldErrors = e.fieldErrors);
      showApiError(context, e);
    } catch (e) {
      if (!mounted) return;
      showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: Text(_existingId == null ? 'New tour' : 'Edit tour')),
      bottomNavigationBar: SubmitBar(
        label: _existingId == null ? 'Create tour' : 'Save changes',
        busy: _busy,
        onSubmit: _save,
        note: 'Planning is self-service — no approval needed before you travel.',
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          children: [
            FormSectionCard(
              title: 'Tour',
              children: [
                AppTextField(
                  label: 'Title',
                  controller: _title,
                  required: true,
                  hint: 'e.g. Nagpur — distributor review',
                  errorText: _fieldErrors['title'],
                ),
                AppTextField(
                  label: 'Purpose',
                  controller: _purpose,
                  maxLines: 2,
                  hint: 'What this trip is for',
                ),
                AppTextField(
                  label: 'Destination city',
                  controller: _destination,
                  hint: 'e.g. Nagpur',
                ),
              ],
            ),
            FormSectionCard(
              title: 'Dates',
              subtitle: 'A single-day tour is fine — start and end on the same date.',
              children: [
                AppDateField(
                  label: 'Start date',
                  value: _start,
                  required: true,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  onChanged: (date) {
                    if (date == null) return;
                    setState(() {
                      _start = _dateOnly(date);
                      if (_end.isBefore(_start)) _end = _start;
                      _rebuildDays();
                    });
                  },
                ),
                AppDateField(
                  label: 'End date',
                  value: _end,
                  required: true,
                  firstDate: _start,
                  errorText: _fieldErrors['plannedEndDate'],
                  onChanged: (date) {
                    if (date == null) return;
                    setState(() {
                      _end = _dateOnly(date);
                      _rebuildDays();
                    });
                  },
                ),
              ],
            ),
            FormSectionCard(
              title: 'Day plan',
              subtitle: '${_days.length} day${_days.length == 1 ? '' : 's'}. '
                  'Mark travel days so a day with no visits is not read as a missed target.',
              children: [
                for (var i = 0; i < _days.length; i++) _dayEditor(i),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _dayEditor(int index) {
    final day = _days[index];
    final isTravel = day.activityType == DayActivity.travel ||
        day.activityType == DayActivity.mixed;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Day ${day.daySeq} · ${dateFormat.format(day.planDate)}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          AppDropdown<DayActivity>(
            label: 'What happens this day',
            items: DayActivity.values,
            value: day.activityType,
            itemLabel: (a) => a.label,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _days[index] = day.copyWith(activityType: value));
            },
          ),
          if (isTravel) ...[
            Row(
              children: [
                Expanded(
                  child: AppTextField(
                    label: 'From',
                    initialValue: day.fromCity,
                    onChanged: (v) => _days[index] = _days[index].copyWith(fromCity: v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppTextField(
                    label: 'To',
                    initialValue: day.toCity,
                    onChanged: (v) => _days[index] = _days[index].copyWith(toCity: v),
                  ),
                ),
              ],
            ),
            AppDropdown<TravelMode>(
              label: 'Travel by',
              items: TravelMode.values,
              value: day.plannedTravelMode ?? TravelMode.unknown,
              itemLabel: (m) => m.label,
              onChanged: (value) =>
                  setState(() => _days[index] = day.copyWith(plannedTravelMode: value)),
            ),
          ],
          AppTextField(
            label: 'Overnight at',
            initialValue: day.overnightCity,
            hint: 'Leave blank if returning home',
            onChanged: (v) => _days[index] = _days[index].copyWith(overnightCity: v),
          ),
          AppTextField(
            label: 'Notes',
            initialValue: day.notes,
            maxLines: 2,
            onChanged: (v) => _days[index] = _days[index].copyWith(notes: v),
          ),
        ],
      ),
    );
  }
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
