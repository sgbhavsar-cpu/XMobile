// Domain models mirroring api/openapi.yaml. Hand-written rather than generated: the
// set is small enough to read, and it keeps the build free of codegen so the whole
// app can be analysed and tested in one step.

import 'dart:math' as math;

import 'package:collection/collection.dart';

import 'enums.dart';

// ---------------------------------------------------------------- primitives

class GeoPoint {
  const GeoPoint(this.lat, this.lon, {this.accuracyM});

  final double lat;
  final double lon;
  final double? accuracyM;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        if (accuracyM != null) 'accuracyM': accuracyM,
      };

  static GeoPoint? fromJson(Map<String, dynamic>? json) => json == null
      ? null
      : GeoPoint(
          (json['lat'] as num).toDouble(),
          (json['lon'] as num).toDouble(),
          accuracyM: (json['accuracyM'] as num?)?.toDouble(),
        );

  /// Metres between two points (haversine), for check-in distance checks.
  double distanceTo(GeoPoint other) {
    const earthRadiusM = 6371008.8;
    double toRad(double d) => d * math.pi / 180.0;
    final dLat = toRad(other.lat - lat);
    final dLon = toRad(other.lon - lon);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat)) * math.cos(toRad(other.lat)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
  }

  @override
  String toString() => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
}

// ---------------------------------------------------------------- identity

class AppUser {
  const AppUser({
    required this.id,
    required this.employeeCode,
    required this.fullName,
    required this.roles,
    this.email,
    this.phone,
    this.grade,
    this.homeLocation,
    this.orgUnitName,
    this.managerName,
  });

  final String id;
  final String employeeCode;
  final String fullName;
  final List<String> roles;
  final String? email;
  final String? phone;
  final String? grade;
  final HomeLocation? homeLocation;
  final String? orgUnitName;
  final String? managerName;

  bool get isManager => roles.contains('MANAGER');
}

class HomeLocation {
  const HomeLocation({
    required this.id,
    required this.label,
    required this.point,
    required this.geofenceRadiusM,
    this.city,
    this.addressLine1,
  });

  final String id;
  final String label;
  final GeoPoint point;
  final int geofenceRadiusM;
  final String? city;
  final String? addressLine1;

  HomeLocation copyWith({GeoPoint? point, int? geofenceRadiusM, String? city, String? addressLine1}) =>
      HomeLocation(
        id: id,
        label: label,
        point: point ?? this.point,
        geofenceRadiusM: geofenceRadiusM ?? this.geofenceRadiusM,
        city: city ?? this.city,
        addressLine1: addressLine1 ?? this.addressLine1,
      );
}

// ---------------------------------------------------------------- customers

class Customer {
  const Customer({
    required this.id,
    required this.name,
    required this.lifecycleStatus,
    this.xinfoId,
    this.accountType,
    this.category,
    this.phone,
    this.email,
    this.gstNumber,
    this.sites = const [],
    this.contacts = const [],
    this.isFieldCreated = false,
    this.rejectionReason,
  });

  final String id;
  final String name;
  final AccountLifecycle lifecycleStatus;
  final String? xinfoId;
  final String? accountType;
  final String? category;
  final String? phone;
  final String? email;
  final String? gstNumber;
  final List<CustomerSite> sites;
  final List<CustomerContact> contacts;
  final bool isFieldCreated;
  final String? rejectionReason;

  CustomerSite? get primarySite =>
      sites.firstWhereOrNull((s) => s.isPrimary) ?? sites.firstOrNull;

  /// A prospect is visitable immediately — that is the whole point of proposing it.
  bool get isVisitable => lifecycleStatus != AccountLifecycle.rejected;

  Customer copyWith({
    String? name,
    AccountLifecycle? lifecycleStatus,
    String? xinfoId,
    String? accountType,
    String? phone,
    String? email,
    String? gstNumber,
    List<CustomerSite>? sites,
    List<CustomerContact>? contacts,
    String? rejectionReason,
  }) =>
      Customer(
        id: id,
        name: name ?? this.name,
        lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
        xinfoId: xinfoId ?? this.xinfoId,
        accountType: accountType ?? this.accountType,
        category: category,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        gstNumber: gstNumber ?? this.gstNumber,
        sites: sites ?? this.sites,
        contacts: contacts ?? this.contacts,
        isFieldCreated: isFieldCreated,
        rejectionReason: rejectionReason ?? this.rejectionReason,
      );
}

class CustomerSite {
  const CustomerSite({
    required this.id,
    required this.customerId,
    required this.name,
    this.point,
    this.geoSource = GeoSource.none,
    this.geofenceRadiusM = 150,
    this.addressLine1,
    this.city,
    this.state,
    this.postalCode,
    this.isPrimary = false,
  });

  final String id;
  final String customerId;
  final String name;
  final GeoPoint? point;
  final GeoSource geoSource;
  final int geofenceRadiusM;
  final String? addressLine1;
  final String? city;
  final String? state;
  final String? postalCode;
  final bool isPrimary;

  bool get hasLocation => point != null;

  String get addressSummary =>
      [addressLine1, city, state].where((s) => s != null && s.isNotEmpty).join(', ');

  CustomerSite copyWith({
    String? name,
    GeoPoint? point,
    GeoSource? geoSource,
    int? geofenceRadiusM,
    String? addressLine1,
    String? city,
    String? state,
    String? postalCode,
    bool? isPrimary,
  }) =>
      CustomerSite(
        id: id,
        customerId: customerId,
        name: name ?? this.name,
        point: point ?? this.point,
        geoSource: geoSource ?? this.geoSource,
        geofenceRadiusM: geofenceRadiusM ?? this.geofenceRadiusM,
        addressLine1: addressLine1 ?? this.addressLine1,
        city: city ?? this.city,
        state: state ?? this.state,
        postalCode: postalCode ?? this.postalCode,
        isPrimary: isPrimary ?? this.isPrimary,
      );
}

class CustomerContact {
  const CustomerContact({
    required this.id,
    required this.customerId,
    required this.fullName,
    this.designation,
    this.phone,
    this.email,
    this.isPrimary = false,
  });

  final String id;
  final String customerId;
  final String fullName;
  final String? designation;
  final String? phone;
  final String? email;
  final bool isPrimary;
}

class Customer360 {
  const Customer360({
    required this.customerId,
    required this.name,
    required this.lifecycleStatus,
    this.category,
    this.siteCount = 0,
    this.lastVisitAt,
    this.visits90d = 0,
    this.sales12m = 0,
    this.lastOrderDate,
    this.openOpportunities = 0,
    this.openPipelineValue = 0,
    this.salesAsOf,
  });

  final String customerId;
  final String name;
  final AccountLifecycle lifecycleStatus;
  final String? category;
  final int siteCount;
  final DateTime? lastVisitAt;
  final int visits90d;
  final double sales12m;
  final DateTime? lastOrderDate;
  final int openOpportunities;
  final double openPipelineValue;

  /// Cached XInfo data is shown with its age — a stale balance presented as current
  /// is worse than showing none.
  final DateTime? salesAsOf;
}

class SalesHistoryItem {
  const SalesHistoryItem({
    required this.id,
    required this.documentType,
    required this.documentDate,
    required this.amount,
    this.documentNo,
    this.status,
    this.summary,
  });

  final String id;
  final String documentType;
  final DateTime documentDate;
  final double amount;
  final String? documentNo;
  final String? status;
  final String? summary;
}

// ---------------------------------------------------------------- opportunities

class OpportunityStage {
  const OpportunityStage({
    required this.code,
    required this.name,
    required this.probabilityPct,
    required this.isWon,
    required this.isLost,
    required this.requiresReason,
    required this.sortOrder,
  });

  final String code;
  final String name;
  final int probabilityPct;
  final bool isWon;
  final bool isLost;
  final bool requiresReason;
  final int sortOrder;

  bool get isOpen => !isWon && !isLost;
}

class Opportunity {
  const Opportunity({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.title,
    required this.stageCode,
    this.xinfoId,
    this.siteId,
    this.description,
    this.estimatedValue,
    this.expectedCloseDate,
    this.probabilityPct,
    this.competitor,
    this.source,
    this.closedAt,
    this.closeReasonCode,
    this.actualValue,
    this.isFieldCreated = false,
    this.repFieldsUpdatedAt,
  });

  final String id;
  final String customerId;
  final String customerName;
  final String title;
  final String stageCode;
  final String? xinfoId;
  final String? siteId;
  final String? description;
  final double? estimatedValue;
  final DateTime? expectedCloseDate;
  final int? probabilityPct;
  final String? competitor;
  final String? source;
  final DateTime? closedAt;
  final String? closeReasonCode;
  final double? actualValue;
  final bool isFieldCreated;
  final DateTime? repFieldsUpdatedAt;

  bool get isOverdue =>
      closedAt == null &&
      expectedCloseDate != null &&
      expectedCloseDate!.isBefore(DateTime.now());

  Opportunity copyWith({
    String? title,
    String? stageCode,
    String? description,
    double? estimatedValue,
    DateTime? expectedCloseDate,
    int? probabilityPct,
    String? competitor,
    DateTime? closedAt,
    String? closeReasonCode,
    double? actualValue,
    DateTime? repFieldsUpdatedAt,
  }) =>
      Opportunity(
        id: id,
        customerId: customerId,
        customerName: customerName,
        title: title ?? this.title,
        stageCode: stageCode ?? this.stageCode,
        xinfoId: xinfoId,
        siteId: siteId,
        description: description ?? this.description,
        estimatedValue: estimatedValue ?? this.estimatedValue,
        expectedCloseDate: expectedCloseDate ?? this.expectedCloseDate,
        probabilityPct: probabilityPct ?? this.probabilityPct,
        competitor: competitor ?? this.competitor,
        source: source,
        closedAt: closedAt ?? this.closedAt,
        closeReasonCode: closeReasonCode ?? this.closeReasonCode,
        actualValue: actualValue ?? this.actualValue,
        isFieldCreated: isFieldCreated,
        repFieldsUpdatedAt: repFieldsUpdatedAt ?? this.repFieldsUpdatedAt,
      );
}

class OpportunityStageChange {
  const OpportunityStageChange({
    required this.toStage,
    required this.changedAt,
    this.fromStage,
    this.visitId,
    this.valueBefore,
    this.valueAfter,
    this.reason,
  });

  final String toStage;
  final DateTime changedAt;
  final String? fromStage;
  final String? visitId;
  final double? valueBefore;
  final double? valueAfter;
  final String? reason;
}

// ---------------------------------------------------------------- planning

class Tour {
  const Tour({
    required this.id,
    required this.title,
    required this.plannedStartDate,
    required this.plannedEndDate,
    required this.status,
    this.purpose,
    this.destinationCity,
    this.actualStartAt,
    this.actualEndAt,
    this.days = const [],
    this.totalDistanceM = 0,
    this.totalVisits = 0,
    this.totalExpenseAmount = 0,
  });

  final String id;
  final String title;
  final DateTime plannedStartDate;
  final DateTime plannedEndDate;
  final TourStatus status;
  final String? purpose;
  final String? destinationCity;
  final DateTime? actualStartAt;
  final DateTime? actualEndAt;
  final List<TourDay> days;
  final int totalDistanceM;
  final int totalVisits;
  final double totalExpenseAmount;

  bool get isSingleDay => plannedStartDate == plannedEndDate;

  int get dayCount => plannedEndDate.difference(plannedStartDate).inDays + 1;

  Tour copyWith({
    String? title,
    DateTime? plannedStartDate,
    DateTime? plannedEndDate,
    TourStatus? status,
    String? purpose,
    String? destinationCity,
    DateTime? actualStartAt,
    DateTime? actualEndAt,
    List<TourDay>? days,
  }) =>
      Tour(
        id: id,
        title: title ?? this.title,
        plannedStartDate: plannedStartDate ?? this.plannedStartDate,
        plannedEndDate: plannedEndDate ?? this.plannedEndDate,
        status: status ?? this.status,
        purpose: purpose ?? this.purpose,
        destinationCity: destinationCity ?? this.destinationCity,
        actualStartAt: actualStartAt ?? this.actualStartAt,
        actualEndAt: actualEndAt ?? this.actualEndAt,
        days: days ?? this.days,
        totalDistanceM: totalDistanceM,
        totalVisits: totalVisits,
        totalExpenseAmount: totalExpenseAmount,
      );
}

class TourDay {
  const TourDay({
    required this.id,
    required this.tourId,
    required this.planDate,
    required this.daySeq,
    required this.activityType,
    this.fromCity,
    this.toCity,
    this.plannedTravelMode,
    this.overnightCity,
    this.notes,
  });

  final String id;
  final String tourId;
  final DateTime planDate;
  final int daySeq;
  final DayActivity activityType;
  final String? fromCity;
  final String? toCity;
  final TravelMode? plannedTravelMode;
  final String? overnightCity;
  final String? notes;

  TourDay copyWith({
    DayActivity? activityType,
    String? fromCity,
    String? toCity,
    TravelMode? plannedTravelMode,
    String? overnightCity,
    String? notes,
  }) =>
      TourDay(
        id: id,
        tourId: tourId,
        planDate: planDate,
        daySeq: daySeq,
        activityType: activityType ?? this.activityType,
        fromCity: fromCity ?? this.fromCity,
        toCity: toCity ?? this.toCity,
        plannedTravelMode: plannedTravelMode ?? this.plannedTravelMode,
        overnightCity: overnightCity ?? this.overnightCity,
        notes: notes ?? this.notes,
      );
}

class VisitPlan {
  const VisitPlan({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.siteId,
    required this.siteName,
    required this.visitTypeCode,
    required this.plannedDate,
    required this.status,
    this.tourId,
    this.tourDayId,
    this.contactId,
    this.plannedStartTime,
    this.seq = 1,
    this.objective,
    this.skipReasonCode,
    this.skipRemark,
    this.isBaseline = true,
  });

  final String id;
  final String customerId;
  final String customerName;
  final String siteId;
  final String siteName;
  final String visitTypeCode;
  final DateTime plannedDate;
  final PlanStatus status;
  final String? tourId;
  final String? tourDayId;
  final String? contactId;
  final String? plannedStartTime;
  final int seq;
  final String? objective;
  final String? skipReasonCode;
  final String? skipRemark;
  final bool isBaseline;

  VisitPlan copyWith({
    PlanStatus? status,
    int? seq,
    String? objective,
    String? plannedStartTime,
    DateTime? plannedDate,
    String? skipReasonCode,
    String? skipRemark,
  }) =>
      VisitPlan(
        id: id,
        customerId: customerId,
        customerName: customerName,
        siteId: siteId,
        siteName: siteName,
        visitTypeCode: visitTypeCode,
        plannedDate: plannedDate ?? this.plannedDate,
        status: status ?? this.status,
        tourId: tourId,
        tourDayId: tourDayId,
        contactId: contactId,
        plannedStartTime: plannedStartTime ?? this.plannedStartTime,
        seq: seq ?? this.seq,
        objective: objective ?? this.objective,
        skipReasonCode: skipReasonCode ?? this.skipReasonCode,
        skipRemark: skipRemark ?? this.skipRemark,
        isBaseline: isBaseline,
      );
}

// ---------------------------------------------------------------- visits

class Visit {
  const Visit({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.siteId,
    required this.siteName,
    required this.visitTypeCode,
    required this.checkInAt,
    required this.status,
    this.visitPlanId,
    this.tourId,
    this.contactId,
    this.checkInPoint,
    this.checkInDistanceM,
    this.checkInMethod = CheckInMethod.manual,
    this.isOutOfGeofence = false,
    this.outOfFenceReasonCode,
    this.outOfFenceRemark,
    this.checkOutAt,
    this.checkOutPoint,
    this.isUnplanned = false,
    this.autoClosed = false,
    this.photoIds = const [],
  });

  final String id;
  final String customerId;
  final String customerName;
  final String siteId;
  final String siteName;
  final String visitTypeCode;
  final DateTime checkInAt;
  final VisitStatus status;
  final String? visitPlanId;
  final String? tourId;
  final String? contactId;
  final GeoPoint? checkInPoint;
  final int? checkInDistanceM;
  final CheckInMethod checkInMethod;
  final bool isOutOfGeofence;
  final String? outOfFenceReasonCode;
  final String? outOfFenceRemark;
  final DateTime? checkOutAt;
  final GeoPoint? checkOutPoint;
  final bool isUnplanned;
  final bool autoClosed;
  final List<String> photoIds;

  Duration? get duration => checkOutAt?.difference(checkInAt);

  bool get isOpen => status == VisitStatus.checkedIn;

  Visit copyWith({
    VisitStatus? status,
    DateTime? checkOutAt,
    GeoPoint? checkOutPoint,
    List<String>? photoIds,
    String? contactId,
  }) =>
      Visit(
        id: id,
        customerId: customerId,
        customerName: customerName,
        siteId: siteId,
        siteName: siteName,
        visitTypeCode: visitTypeCode,
        checkInAt: checkInAt,
        status: status ?? this.status,
        visitPlanId: visitPlanId,
        tourId: tourId,
        contactId: contactId ?? this.contactId,
        checkInPoint: checkInPoint,
        checkInDistanceM: checkInDistanceM,
        checkInMethod: checkInMethod,
        isOutOfGeofence: isOutOfGeofence,
        outOfFenceReasonCode: outOfFenceReasonCode,
        outOfFenceRemark: outOfFenceRemark,
        checkOutAt: checkOutAt ?? this.checkOutAt,
        checkOutPoint: checkOutPoint ?? this.checkOutPoint,
        isUnplanned: isUnplanned,
        autoClosed: autoClosed,
        photoIds: photoIds ?? this.photoIds,
      );
}

class VisitReport {
  const VisitReport({
    required this.visitId,
    this.templateCode,
    this.templateVersion,
    this.outcomeCode,
    this.summary,
    this.discussionPoints,
    this.nextAction,
    this.followUpDate,
    this.orderIntent = false,
    this.orderValueEst,
    this.competitorSeen = false,
    this.competitorNotes,
    this.customerSentiment,
    this.issuesRaised,
    this.contactMetId,
    this.contactMetName,
    this.answers = const {},
    this.isDraft = true,
    this.submittedAt,
  });

  final String visitId;
  final String? templateCode;
  final int? templateVersion;
  final String? outcomeCode;
  final String? summary;
  final String? discussionPoints;
  final String? nextAction;
  final DateTime? followUpDate;
  final bool orderIntent;
  final double? orderValueEst;
  final bool competitorSeen;
  final String? competitorNotes;
  final int? customerSentiment;
  final String? issuesRaised;
  final String? contactMetId;
  final String? contactMetName;

  /// Dynamic section, validated against the pinned template version.
  final Map<String, dynamic> answers;

  final bool isDraft;
  final DateTime? submittedAt;

  VisitReport copyWith({
    String? templateCode,
    int? templateVersion,
    String? outcomeCode,
    String? summary,
    String? discussionPoints,
    String? nextAction,
    DateTime? followUpDate,
    bool? orderIntent,
    double? orderValueEst,
    bool? competitorSeen,
    String? competitorNotes,
    int? customerSentiment,
    String? issuesRaised,
    String? contactMetId,
    String? contactMetName,
    Map<String, dynamic>? answers,
    bool? isDraft,
    DateTime? submittedAt,
  }) =>
      VisitReport(
        visitId: visitId,
        templateCode: templateCode ?? this.templateCode,
        templateVersion: templateVersion ?? this.templateVersion,
        outcomeCode: outcomeCode ?? this.outcomeCode,
        summary: summary ?? this.summary,
        discussionPoints: discussionPoints ?? this.discussionPoints,
        nextAction: nextAction ?? this.nextAction,
        followUpDate: followUpDate ?? this.followUpDate,
        orderIntent: orderIntent ?? this.orderIntent,
        orderValueEst: orderValueEst ?? this.orderValueEst,
        competitorSeen: competitorSeen ?? this.competitorSeen,
        competitorNotes: competitorNotes ?? this.competitorNotes,
        customerSentiment: customerSentiment ?? this.customerSentiment,
        issuesRaised: issuesRaised ?? this.issuesRaised,
        contactMetId: contactMetId ?? this.contactMetId,
        contactMetName: contactMetName ?? this.contactMetName,
        answers: answers ?? this.answers,
        isDraft: isDraft ?? this.isDraft,
        submittedAt: submittedAt ?? this.submittedAt,
      );
}

// ---------------------------------------------------------------- reference

class VisitType {
  const VisitType({
    required this.code,
    required this.name,
    this.defaultDurationMin = 45,
    this.requiresSelfie = false,
    this.allowsRemote = false,
    this.defaultTemplateCode,
  });

  final String code;
  final String name;
  final int defaultDurationMin;
  final bool requiresSelfie;
  final bool allowsRemote;
  final String? defaultTemplateCode;
}

class VisitOutcome {
  const VisitOutcome({
    required this.code,
    required this.name,
    this.isPositive = true,
    this.requiresFollowUp = false,
  });

  final String code;
  final String name;
  final bool isPositive;
  final bool requiresFollowUp;
}

class ReasonCode {
  const ReasonCode({
    required this.domain,
    required this.code,
    required this.name,
    this.requiresRemark = false,
  });

  final String domain;
  final String code;
  final String name;
  final bool requiresRemark;
}

class ExpenseCategory {
  const ExpenseCategory({
    required this.code,
    required this.name,
    this.requiresReceipt = true,
    this.receiptThreshold,
    this.isDistanceBased = false,
    this.isPerDiem = false,
    this.requiresRoute = false,
    this.requiresTour = false,
    this.dailyCap,
  });

  final String code;
  final String name;
  final bool requiresReceipt;
  final double? receiptThreshold;
  final bool isDistanceBased;
  final bool isPerDiem;
  final bool requiresRoute;
  final bool requiresTour;
  final double? dailyCap;

  bool receiptRequiredFor(double amount) {
    if (!requiresReceipt) return false;
    if (receiptThreshold == null) return true;
    return amount >= receiptThreshold!;
  }
}

// ---------------------------------------------------------------- expenses

class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.captureSource = CaptureSource.manual,
    this.sourceApp,
    this.capturedAt,
    this.isUploaded = false,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final CaptureSource captureSource;
  final String? sourceApp;
  final DateTime? capturedAt;
  final bool isUploaded;

  bool get isPdf => mimeType == 'application/pdf';
}

class OcrResult {
  const OcrResult({
    this.docType,
    this.amount,
    this.txnDate,
    this.merchantName,
    this.paymentRef,
    this.paymentMode,
    this.confidence,
  });

  final String? docType;
  final double? amount;
  final DateTime? txnDate;
  final String? merchantName;
  final String? paymentRef;
  final String? paymentMode;
  final double? confidence;
}

class Expense {
  const Expense({
    required this.id,
    required this.categoryCode,
    required this.expenseDate,
    required this.amount,
    required this.status,
    this.tourId,
    this.visitId,
    this.currency = 'INR',
    this.paymentMode,
    this.merchantName,
    this.paymentRef,
    this.description,
    this.travelMode,
    this.fromPlace,
    this.toPlace,
    this.distanceKm,
    this.distanceSource,
    this.captureSource = CaptureSource.manual,
    this.sourceApp,
    this.attachmentIds = const [],
    this.suggestedAmount,
    this.suggestedBasis,
    this.xinfoStatus,
    this.xinfoRemark,
    this.settledAmount,
    this.submittedAt,
  });

  final String id;
  final String categoryCode;
  final DateTime expenseDate;
  final double amount;
  final ExpenseStatus status;
  final String? tourId;
  final String? visitId;
  final String currency;
  final String? paymentMode;
  final String? merchantName;
  final String? paymentRef;
  final String? description;
  final TravelMode? travelMode;
  final String? fromPlace;
  final String? toPlace;
  final double? distanceKm;
  final String? distanceSource;
  final CaptureSource captureSource;
  final String? sourceApp;
  final List<String> attachmentIds;

  /// Indicative figure from the synced rate tables. XInfo decides finally.
  final double? suggestedAmount;
  final String? suggestedBasis;

  final String? xinfoStatus;
  final String? xinfoRemark;
  final double? settledAmount;
  final DateTime? submittedAt;

  Expense copyWith({
    String? categoryCode,
    DateTime? expenseDate,
    double? amount,
    ExpenseStatus? status,
    String? tourId,
    String? paymentMode,
    String? merchantName,
    String? paymentRef,
    String? description,
    TravelMode? travelMode,
    String? fromPlace,
    String? toPlace,
    double? distanceKm,
    List<String>? attachmentIds,
    DateTime? submittedAt,
    String? xinfoStatus,
  }) =>
      Expense(
        id: id,
        categoryCode: categoryCode ?? this.categoryCode,
        expenseDate: expenseDate ?? this.expenseDate,
        amount: amount ?? this.amount,
        status: status ?? this.status,
        tourId: tourId ?? this.tourId,
        visitId: visitId,
        currency: currency,
        paymentMode: paymentMode ?? this.paymentMode,
        merchantName: merchantName ?? this.merchantName,
        paymentRef: paymentRef ?? this.paymentRef,
        description: description ?? this.description,
        travelMode: travelMode ?? this.travelMode,
        fromPlace: fromPlace ?? this.fromPlace,
        toPlace: toPlace ?? this.toPlace,
        distanceKm: distanceKm ?? this.distanceKm,
        distanceSource: distanceSource,
        captureSource: captureSource,
        sourceApp: sourceApp,
        attachmentIds: attachmentIds ?? this.attachmentIds,
        suggestedAmount: suggestedAmount,
        suggestedBasis: suggestedBasis,
        xinfoStatus: xinfoStatus ?? this.xinfoStatus,
        xinfoRemark: xinfoRemark,
        settledAmount: settledAmount,
        submittedAt: submittedAt ?? this.submittedAt,
      );
}

class ShareInboxItem {
  const ShareInboxItem({
    required this.id,
    required this.receivedAt,
    required this.attachment,
    this.sourceApp,
    this.sharedText,
    this.ocr,
    this.suggestedCategoryCode,
    this.status = 'PENDING',
    this.expenseId,
  });

  final String id;
  final DateTime receivedAt;
  final Attachment attachment;
  final String? sourceApp;
  final String? sharedText;
  final OcrResult? ocr;
  final String? suggestedCategoryCode;
  final String status;
  final String? expenseId;
}

class MileageSuggestion {
  const MileageSuggestion({
    required this.distanceKm,
    required this.estimatedPortionKm,
    required this.travelMode,
    this.ratePerKm,
    this.suggestedAmount,
  });

  final double distanceKm;
  final double estimatedPortionKm;
  final TravelMode travelMode;
  final double? ratePerKm;
  final double? suggestedAmount;
}

// ---------------------------------------------------------------- journey

class JourneyEvent {
  const JourneyEvent({
    required this.id,
    required this.type,
    required this.occurredAt,
    required this.status,
    this.confidence = 1.0,
    this.point,
    this.placeName,
    this.customerId,
    this.method,
    this.isEstimated = false,
    this.isManual = false,
    this.originalOccurredAt,
  });

  final String id;
  final JourneyEventType type;
  final DateTime occurredAt;
  final EventStatus status;
  final double confidence;
  final GeoPoint? point;
  final String? placeName;
  final String? customerId;
  final String? method;
  final bool isEstimated;
  final bool isManual;
  final DateTime? originalOccurredAt;

  JourneyEvent copyWith({
    DateTime? occurredAt,
    EventStatus? status,
    double? confidence,
    bool? isManual,
    DateTime? originalOccurredAt,
  }) =>
      JourneyEvent(
        id: id,
        type: type,
        occurredAt: occurredAt ?? this.occurredAt,
        status: status ?? this.status,
        confidence: confidence ?? this.confidence,
        point: point,
        placeName: placeName,
        customerId: customerId,
        method: method,
        isEstimated: isEstimated,
        isManual: isManual ?? this.isManual,
        originalOccurredAt: originalOccurredAt ?? this.originalOccurredAt,
      );
}

class JourneySegment {
  const JourneySegment({
    required this.id,
    required this.type,
    required this.startedAt,
    this.endedAt,
    this.distanceM = 0,
    this.travelMode = TravelMode.unknown,
    this.placeName,
    this.isEstimated = false,
    this.isProvisional = false,
  });

  final String id;
  final String type;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int distanceM;
  final TravelMode travelMode;
  final String? placeName;
  final bool isEstimated;
  final bool isProvisional;

  Duration? get duration => endedAt?.difference(startedAt);
  bool get isTravel => type.contains('TRAVEL');
}

class DaySummary {
  const DaySummary({
    required this.localDate,
    this.firstDepartureAt,
    this.lastArrivalAt,
    this.totalDistanceM = 0,
    this.travelTimeS = 0,
    this.customerTimeS = 0,
    this.visitsPlanned = 0,
    this.visitsCompleted = 0,
    this.trackingCoveragePct,
    this.attendanceStatus,
  });

  final DateTime localDate;
  final DateTime? firstDepartureAt;
  final DateTime? lastArrivalAt;
  final int totalDistanceM;
  final int travelTimeS;
  final int customerTimeS;
  final int visitsPlanned;
  final int visitsCompleted;
  final int? trackingCoveragePct;
  final String? attendanceStatus;
}

class TrackingHealth {
  const TrackingHealth({
    required this.locationPermission,
    required this.batteryOptimised,
    required this.notificationsAllowed,
    required this.activityPermission,
    required this.autostartConfigured,
    this.isPowerSaving = false,
    this.lastUploadAt,
    this.queuedPings = 0,
  });

  final String locationPermission;
  final bool batteryOptimised;
  final bool notificationsAllowed;
  final bool activityPermission;
  final bool autostartConfigured;
  final bool isPowerSaving;
  final DateTime? lastUploadAt;
  final int queuedPings;

  /// Same score the manager sees, so a gap conversation starts from a shared checklist.
  int get score {
    var score = 100;
    if (locationPermission != 'ALWAYS') score -= 40;
    if (batteryOptimised) score -= 25;
    if (!autostartConfigured) score -= 15;
    if (!notificationsAllowed) score -= 10;
    if (!activityPermission) score -= 5;
    if (isPowerSaving) score -= 5;
    return score.clamp(0, 100);
  }

  List<String> get issues => [
        if (locationPermission != 'ALWAYS')
          'Location permission is "$locationPermission" — tracking needs "Always"',
        if (batteryOptimised) 'Battery optimisation may stop tracking in the background',
        if (!autostartConfigured) 'Autostart is not enabled for this device brand',
        if (!notificationsAllowed) 'Notifications are blocked — the tracking indicator is hidden',
        if (!activityPermission) 'Physical activity permission is off — motion detection is degraded',
        if (isPowerSaving) 'Power saving is on — location updates will be less frequent',
      ];

  TrackingHealth copyWith({
    String? locationPermission,
    bool? batteryOptimised,
    bool? notificationsAllowed,
    bool? activityPermission,
    bool? autostartConfigured,
    bool? isPowerSaving,
  }) =>
      TrackingHealth(
        locationPermission: locationPermission ?? this.locationPermission,
        batteryOptimised: batteryOptimised ?? this.batteryOptimised,
        notificationsAllowed: notificationsAllowed ?? this.notificationsAllowed,
        activityPermission: activityPermission ?? this.activityPermission,
        autostartConfigured: autostartConfigured ?? this.autostartConfigured,
        isPowerSaving: isPowerSaving ?? this.isPowerSaving,
        lastUploadAt: lastUploadAt,
        queuedPings: queuedPings,
      );
}

// ---------------------------------------------------------------- sync

class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.operation,
    required this.description,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
    this.state = SyncState.pending,
  });

  final String id;
  final String entity;
  final String entityId;
  final String operation;
  final String description;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
  final SyncState state;

  OutboxEntry copyWith({int? attempts, String? lastError, SyncState? state}) => OutboxEntry(
        id: id,
        entity: entity,
        entityId: entityId,
        operation: operation,
        description: description,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        state: state ?? this.state,
      );
}

class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.reason,
    required this.description,
    required this.detectedAt,
    required this.mineSummary,
    required this.serverSummary,
  });

  final String id;
  final String entity;
  final String entityId;
  final String reason;
  final String description;
  final DateTime detectedAt;
  final String mineSummary;
  final String serverSummary;
}

// ---------------------------------------------------------------- dynamic forms

/// A field in an admin-defined form template. Rendered from the template schema so
/// the questions can change without an app release.
class FormFieldDef {
  const FormFieldDef({
    required this.key,
    required this.type,
    required this.label,
    this.required = false,
    this.options = const [],
    this.min,
    this.max,
    this.maxLength,
    this.visibleIfField,
    this.visibleIfEquals,
    this.helpText,
  });

  final String key;
  final String type; // text | number | bool | choice | multichoice | date | rating | photo
  final String label;
  final bool required;
  final List<String> options;
  final num? min;
  final num? max;
  final int? maxLength;
  final String? visibleIfField;
  final Object? visibleIfEquals;
  final String? helpText;

  bool isVisible(Map<String, dynamic> answers) {
    if (visibleIfField == null) return true;
    return answers[visibleIfField] == visibleIfEquals;
  }

  static FormFieldDef fromJson(Map<String, dynamic> json) {
    final visibleIf = json['visibleIf'] as Map<String, dynamic>?;
    return FormFieldDef(
      key: json['key'] as String,
      type: json['type'] as String,
      label: json['label'] as String,
      required: json['required'] as bool? ?? false,
      options: (json['options'] as List?)?.cast<String>() ?? const [],
      min: json['min'] as num?,
      max: json['max'] as num?,
      maxLength: json['maxLength'] as int?,
      visibleIfField: visibleIf?['field'] as String?,
      visibleIfEquals: visibleIf?['eq'],
      helpText: json['help'] as String?,
    );
  }
}

class FormSection {
  const FormSection({required this.key, required this.title, required this.fields});

  final String key;
  final String title;
  final List<FormFieldDef> fields;

  static FormSection fromJson(Map<String, dynamic> json) => FormSection(
        key: json['key'] as String,
        title: json['title'] as String,
        fields: (json['fields'] as List)
            .map((f) => FormFieldDef.fromJson(f as Map<String, dynamic>))
            .toList(),
      );
}

class FormTemplate {
  const FormTemplate({
    required this.code,
    required this.version,
    required this.name,
    required this.sections,
    this.visitTypeCode,
  });

  final String code;
  final int version;
  final String name;
  final List<FormSection> sections;
  final String? visitTypeCode;

  static FormTemplate fromJson(Map<String, dynamic> json) => FormTemplate(
        code: json['code'] as String,
        version: json['version'] as int,
        name: json['name'] as String,
        visitTypeCode: json['visitTypeCode'] as String?,
        sections: ((json['schema'] as Map<String, dynamic>)['sections'] as List)
            .map((s) => FormSection.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}
