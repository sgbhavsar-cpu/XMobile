import 'package:collection/collection.dart';

import '../models/enums.dart';
import '../models/models.dart';

/// A realistic Pune territory with a Nagpur tour in progress, so the app opens onto
/// something worth looking at rather than empty lists. Dates are relative to today,
/// which keeps "today's plan" meaningful whenever the app is run.
abstract final class SeedData {
  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
      _today.add(Duration(days: dayOffset)).add(Duration(hours: hour, minutes: minute));

  // ------------------------------------------------------------------ identity

  static final homeLocation = HomeLocation(
    id: 'home-1',
    label: 'Home',
    point: const GeoPoint(18.5204, 73.8567),
    geofenceRadiusM: 200,
    city: 'Pune',
    addressLine1: 'Flat 402, Sunrise Residency, Kothrud',
  );

  static AppUser user(HomeLocation home) => AppUser(
        id: 'user-1',
        employeeCode: 'E1001',
        fullName: 'Field Rep One',
        roles: const ['SALES_REP'],
        email: 'rep1@example.com',
        phone: '+91 98200 11001',
        grade: 'M2',
        homeLocation: home,
        orgUnitName: 'Pune Area',
        managerName: 'Area Manager',
      );

  static const trackingHealth = TrackingHealth(
    locationPermission: 'WHEN_IN_USE', // deliberately imperfect: the fix flow is worth seeing
    batteryOptimised: true,
    notificationsAllowed: true,
    activityPermission: false,
    autostartConfigured: false,
    queuedPings: 0,
  );

  // ------------------------------------------------------------------ reference

  static const visitTypes = [
    VisitType(code: 'SALES_CALL', name: 'Sales call', defaultTemplateCode: 'STD_SALES_CALL'),
    VisitType(code: 'COLLECTION', name: 'Payment collection', defaultDurationMin: 30),
    VisitType(code: 'SERVICE', name: 'Service / complaint', defaultDurationMin: 60),
    VisitType(code: 'DEMO', name: 'Product demonstration', defaultDurationMin: 90),
    VisitType(code: 'NEW_PROSPECT', name: 'New prospect'),
    VisitType(code: 'COURTESY', name: 'Courtesy / relationship', defaultDurationMin: 30),
    VisitType(code: 'REMOTE_CALL', name: 'Telephonic / online', defaultDurationMin: 20, allowsRemote: true),
  ];

  static const visitOutcomes = [
    VisitOutcome(code: 'ORDER_BOOKED', name: 'Order booked'),
    VisitOutcome(code: 'QUOTE_GIVEN', name: 'Quotation given', requiresFollowUp: true),
    VisitOutcome(code: 'NEGOTIATION', name: 'Under negotiation', requiresFollowUp: true),
    VisitOutcome(code: 'INFO_ONLY', name: 'Information shared'),
    VisitOutcome(code: 'COMPLAINT_LOGGED', name: 'Complaint logged', isPositive: false, requiresFollowUp: true),
    VisitOutcome(code: 'NO_REQUIREMENT', name: 'No current requirement', isPositive: false),
    VisitOutcome(code: 'CONTACT_ABSENT', name: 'Contact not available', isPositive: false, requiresFollowUp: true),
    VisitOutcome(code: 'LOST_TO_COMPETITOR', name: 'Lost to competitor', isPositive: false, requiresFollowUp: true),
  ];

  static const reasonCodes = [
    ReasonCode(domain: 'VISIT_SKIP', code: 'CUSTOMER_UNAVAILABLE', name: 'Customer unavailable'),
    ReasonCode(domain: 'VISIT_SKIP', code: 'TIME_SHORTAGE', name: 'Ran out of time'),
    ReasonCode(domain: 'VISIT_SKIP', code: 'TRAVEL_DELAY', name: 'Travel delay'),
    ReasonCode(domain: 'VISIT_SKIP', code: 'CUSTOMER_CLOSED', name: 'Premises closed'),
    ReasonCode(domain: 'VISIT_SKIP', code: 'PERSONAL_EMERGENCY', name: 'Personal emergency', requiresRemark: true),
    ReasonCode(domain: 'VISIT_SKIP', code: 'OTHER', name: 'Other', requiresRemark: true),
    ReasonCode(domain: 'TRACKING_PAUSE', code: 'PERSONAL_BREAK', name: 'Personal / lunch break'),
    ReasonCode(domain: 'TRACKING_PAUSE', code: 'LOW_BATTERY', name: 'Low battery'),
    ReasonCode(domain: 'TRACKING_PAUSE', code: 'PRIVATE_TRIP', name: 'Personal trip in work hours', requiresRemark: true),
    ReasonCode(domain: 'TRACKING_PAUSE', code: 'DEVICE_ISSUE', name: 'Device problem', requiresRemark: true),
    ReasonCode(domain: 'OUT_OF_GEOFENCE', code: 'MET_OUTSIDE', name: 'Met contact outside premises', requiresRemark: true),
    ReasonCode(domain: 'OUT_OF_GEOFENCE', code: 'WRONG_LOCATION_ON_FILE', name: 'Recorded location is wrong', requiresRemark: true),
    ReasonCode(domain: 'OUT_OF_GEOFENCE', code: 'GPS_INACCURATE', name: 'GPS inaccurate'),
    ReasonCode(domain: 'OPPORTUNITY_CLOSE', code: 'PRICE', name: 'Price'),
    ReasonCode(domain: 'OPPORTUNITY_CLOSE', code: 'COMPETITOR', name: 'Lost to competitor'),
    ReasonCode(domain: 'OPPORTUNITY_CLOSE', code: 'NO_BUDGET', name: 'No budget'),
    ReasonCode(domain: 'OPPORTUNITY_CLOSE', code: 'DEFERRED', name: 'Deferred by customer'),
  ];

  static const expenseCategories = [
    ExpenseCategory(code: 'TRAVEL_AIR', name: 'Air travel', requiresRoute: true, requiresTour: true),
    ExpenseCategory(code: 'TRAVEL_RAIL', name: 'Rail travel', requiresRoute: true, requiresTour: true),
    ExpenseCategory(code: 'TRAVEL_BUS', name: 'Bus travel', requiresRoute: true),
    ExpenseCategory(code: 'TRAVEL_TAXI', name: 'Taxi / cab', receiptThreshold: 200),
    ExpenseCategory(
        code: 'TRAVEL_OWN_VEHICLE',
        name: 'Own vehicle (mileage)',
        requiresReceipt: false,
        isDistanceBased: true,
        requiresRoute: true),
    ExpenseCategory(code: 'FUEL', name: 'Fuel'),
    ExpenseCategory(code: 'TOLL_PARKING', name: 'Toll / parking', receiptThreshold: 100),
    ExpenseCategory(code: 'LODGING', name: 'Hotel / lodging', requiresTour: true),
    ExpenseCategory(code: 'MEALS', name: 'Meals', receiptThreshold: 300),
    ExpenseCategory(
        code: 'DAILY_ALLOWANCE',
        name: 'Daily allowance',
        requiresReceipt: false,
        isPerDiem: true,
        requiresTour: true),
    ExpenseCategory(code: 'CUSTOMER_ENTERTAINMENT', name: 'Customer entertainment'),
    ExpenseCategory(code: 'COMMUNICATION', name: 'Phone / internet'),
    ExpenseCategory(code: 'COURIER', name: 'Courier / postage'),
    ExpenseCategory(code: 'MISC', name: 'Miscellaneous'),
  ];

  static const opportunityStages = [
    OpportunityStage(code: 'IDENTIFIED', name: 'Identified', probabilityPct: 10, isWon: false, isLost: false, requiresReason: false, sortOrder: 10),
    OpportunityStage(code: 'QUALIFIED', name: 'Qualified', probabilityPct: 25, isWon: false, isLost: false, requiresReason: false, sortOrder: 20),
    OpportunityStage(code: 'PROPOSAL', name: 'Proposal sent', probabilityPct: 50, isWon: false, isLost: false, requiresReason: false, sortOrder: 30),
    OpportunityStage(code: 'NEGOTIATION', name: 'Negotiation', probabilityPct: 75, isWon: false, isLost: false, requiresReason: false, sortOrder: 40),
    OpportunityStage(code: 'WON', name: 'Won', probabilityPct: 100, isWon: true, isLost: false, requiresReason: false, sortOrder: 50),
    OpportunityStage(code: 'LOST', name: 'Lost', probabilityPct: 0, isWon: false, isLost: true, requiresReason: true, sortOrder: 60),
    OpportunityStage(code: 'ON_HOLD', name: 'On hold', probabilityPct: 0, isWon: false, isLost: true, requiresReason: true, sortOrder: 70),
  ];

  static OpportunityStage? stageByCode(String code) =>
      opportunityStages.firstWhereOrNull((s) => s.code == code);

  /// The dynamic extension section of a visit report, as an admin would publish it.
  static final formTemplates = [
    FormTemplate.fromJson(const {
      'code': 'STD_SALES_CALL',
      'version': 1,
      'name': 'Standard sales call',
      'visitTypeCode': 'SALES_CALL',
      'schema': {
        'sections': [
          {
            'key': 'stock',
            'title': 'Stock check',
            'fields': [
              {'key': 'stock_checked', 'type': 'bool', 'label': 'Stock checked?', 'required': true},
              {
                'key': 'closing_qty',
                'type': 'number',
                'label': 'Closing quantity',
                'min': 0,
                'visibleIf': {'field': 'stock_checked', 'eq': true}
              },
              {
                'key': 'expiry_issue',
                'type': 'bool',
                'label': 'Near-expiry stock seen?',
                'visibleIf': {'field': 'stock_checked', 'eq': true}
              },
            ],
          },
          {
            'key': 'market',
            'title': 'Market feedback',
            'fields': [
              {
                'key': 'competitor_scheme',
                'type': 'text',
                'label': 'Competitor scheme seen',
                'maxLength': 500
              },
              {
                'key': 'price_feedback',
                'type': 'choice',
                'label': 'Price feedback',
                'options': ['Competitive', 'Slightly high', 'Too high']
              },
              {
                'key': 'relationship',
                'type': 'rating',
                'label': 'Relationship strength',
                'help': '1 = poor, 5 = excellent'
              },
            ],
          },
        ],
      },
    }),
  ];

  // ------------------------------------------------------------------ customers

  static final customers = <Customer>[
    Customer(
      id: 'cust-1',
      name: 'Nagpur Distributors Pvt Ltd',
      lifecycleStatus: AccountLifecycle.active,
      xinfoId: 'XI-9001',
      accountType: 'DISTRIBUTOR',
      category: 'A',
      phone: '+91 712 2345 678',
      sites: const [
        CustomerSite(
          id: 'site-1',
          customerId: 'cust-1',
          name: 'Main Yard',
          point: GeoPoint(21.1458, 79.0882),
          geoSource: GeoSource.fieldCaptured,
          geofenceRadiusM: 250,
          addressLine1: 'Plot 14, MIDC Hingna',
          city: 'Nagpur',
          state: 'Maharashtra',
          isPrimary: true,
        ),
        CustomerSite(
          id: 'site-1b',
          customerId: 'cust-1',
          name: 'City Warehouse',
          point: GeoPoint(21.1305, 79.0700),
          geoSource: GeoSource.geocoded,
          addressLine1: 'Near Sitabuldi Market',
          city: 'Nagpur',
          state: 'Maharashtra',
        ),
      ],
      contacts: const [
        CustomerContact(
          id: 'contact-1',
          customerId: 'cust-1',
          fullName: 'Rajesh Deshmukh',
          designation: 'Purchase Head',
          phone: '+91 98220 33445',
          isPrimary: true,
        ),
        CustomerContact(
          id: 'contact-2',
          customerId: 'cust-1',
          fullName: 'Sunita Kale',
          designation: 'Accounts',
          phone: '+91 98220 33446',
        ),
      ],
    ),
    Customer(
      id: 'cust-2',
      name: 'Kothrud Hardware Stores',
      lifecycleStatus: AccountLifecycle.active,
      xinfoId: 'XI-9002',
      accountType: 'DEALER',
      category: 'B',
      phone: '+91 20 2543 1122',
      sites: const [
        CustomerSite(
          id: 'site-2',
          customerId: 'cust-2',
          name: 'Shop',
          point: GeoPoint(18.5074, 73.8077),
          geoSource: GeoSource.fieldCaptured,
          addressLine1: 'Paud Road, Kothrud',
          city: 'Pune',
          state: 'Maharashtra',
          isPrimary: true,
        ),
      ],
      contacts: const [
        CustomerContact(
          id: 'contact-3',
          customerId: 'cust-2',
          fullName: 'Amit Joshi',
          designation: 'Owner',
          phone: '+91 98500 77881',
          isPrimary: true,
        ),
      ],
    ),
    Customer(
      id: 'cust-3',
      name: 'Baner Trading Company',
      lifecycleStatus: AccountLifecycle.active,
      xinfoId: 'XI-9003',
      accountType: 'RETAILER',
      category: 'C',
      sites: const [
        CustomerSite(
          id: 'site-3',
          customerId: 'cust-3',
          name: 'Main Store',
          // Deliberately geocoded and unverified: arrivals here are held for review,
          // and the "capture location" flow is worth exercising.
          point: GeoPoint(18.5642, 73.7769),
          geoSource: GeoSource.geocoded,
          addressLine1: 'Baner Road',
          city: 'Pune',
          state: 'Maharashtra',
          isPrimary: true,
        ),
      ],
      contacts: const [
        CustomerContact(
          id: 'contact-4',
          customerId: 'cust-3',
          fullName: 'Prakash Rane',
          designation: 'Proprietor',
          phone: '+91 99700 12123',
          isPrimary: true,
        ),
      ],
    ),
    Customer(
      id: 'cust-4',
      name: 'Vidarbha Traders',
      lifecycleStatus: AccountLifecycle.pendingApproval,
      accountType: 'DEALER',
      isFieldCreated: true,
      sites: const [
        CustomerSite(
          id: 'site-4',
          customerId: 'cust-4',
          name: 'Shop',
          point: GeoPoint(21.1502, 79.0921),
          geoSource: GeoSource.fieldCaptured,
          city: 'Nagpur',
          state: 'Maharashtra',
          isPrimary: true,
        ),
      ],
    ),
  ];

  static final salesHistory = <String, List<SalesHistoryItem>>{
    'cust-1': [
      SalesHistoryItem(
        id: 'so-1',
        documentType: 'ORDER',
        documentNo: 'SO/26/1180',
        documentDate: _today.subtract(const Duration(days: 59)),
        amount: 380000,
        status: 'Delivered',
        summary: 'Grade A x40, Grade B x12',
      ),
      SalesHistoryItem(
        id: 'so-2',
        documentType: 'ORDER',
        documentNo: 'SO/26/1442',
        documentDate: _today.subtract(const Duration(days: 14)),
        amount: 265000,
        status: 'In transit',
        summary: 'Grade A x28',
      ),
      SalesHistoryItem(
        id: 'inv-1',
        documentType: 'INVOICE',
        documentNo: 'INV/26/8891',
        documentDate: _today.subtract(const Duration(days: 12)),
        amount: 265000,
        status: 'Unpaid',
      ),
    ],
    'cust-2': [
      SalesHistoryItem(
        id: 'so-3',
        documentType: 'ORDER',
        documentNo: 'SO/26/1501',
        documentDate: _today.subtract(const Duration(days: 21)),
        amount: 48000,
        status: 'Delivered',
        summary: 'Assorted fittings',
      ),
    ],
  };

  static final opportunities = <Opportunity>[
    Opportunity(
      id: 'opp-1',
      customerId: 'cust-1',
      customerName: 'Nagpur Distributors Pvt Ltd',
      title: 'Q4 bulk supply — Grade A',
      stageCode: 'QUALIFIED',
      estimatedValue: 450000,
      expectedCloseDate: _today.add(const Duration(days: 45)),
      siteId: 'site-1',
      source: 'FIELD',
      isFieldCreated: true,
      description: 'Customer wants volume pricing for the festive season.',
    ),
    Opportunity(
      id: 'opp-2',
      customerId: 'cust-2',
      customerName: 'Kothrud Hardware Stores',
      title: 'Annual maintenance contract',
      stageCode: 'PROPOSAL',
      estimatedValue: 120000,
      expectedCloseDate: _today.subtract(const Duration(days: 3)), // overdue on purpose
      siteId: 'site-2',
      competitor: 'Sharma Enterprises',
    ),
    Opportunity(
      id: 'opp-3',
      customerId: 'cust-3',
      customerName: 'Baner Trading Company',
      title: 'New product line trial',
      stageCode: 'IDENTIFIED',
      estimatedValue: 65000,
      expectedCloseDate: _today.add(const Duration(days: 20)),
      siteId: 'site-3',
    ),
  ];

  // ------------------------------------------------------------------ planning

  static final tours = <Tour>[
    Tour(
      id: 'tour-1',
      title: 'Nagpur — distributor review',
      purpose: 'Quarterly review and stock check',
      plannedStartDate: _today.subtract(const Duration(days: 1)),
      plannedEndDate: _today.add(const Duration(days: 2)),
      status: TourStatus.inProgress,
      destinationCity: 'Nagpur',
      actualStartAt: _at(-1, 18, 40),
      days: [
        TourDay(
          id: 'day-1',
          tourId: 'tour-1',
          planDate: _today.subtract(const Duration(days: 1)),
          daySeq: 1,
          activityType: DayActivity.travel,
          fromCity: 'Pune',
          toCity: 'Nagpur',
          plannedTravelMode: TravelMode.rail,
          overnightCity: 'On train',
        ),
        TourDay(
          id: 'day-2',
          tourId: 'tour-1',
          planDate: _today,
          daySeq: 2,
          activityType: DayActivity.visits,
          fromCity: 'Nagpur',
          toCity: 'Nagpur',
          overnightCity: 'Nagpur',
        ),
        TourDay(
          id: 'day-3',
          tourId: 'tour-1',
          planDate: _today.add(const Duration(days: 1)),
          daySeq: 3,
          activityType: DayActivity.mixed,
          fromCity: 'Nagpur',
          toCity: 'Nagpur',
          overnightCity: 'Nagpur',
        ),
        TourDay(
          id: 'day-4',
          tourId: 'tour-1',
          planDate: _today.add(const Duration(days: 2)),
          daySeq: 4,
          activityType: DayActivity.travel,
          fromCity: 'Nagpur',
          toCity: 'Pune',
          plannedTravelMode: TravelMode.rail,
        ),
      ],
    ),
    Tour(
      id: 'tour-2',
      title: 'Pune local — week 33',
      purpose: 'Routine coverage',
      plannedStartDate: _today.add(const Duration(days: 5)),
      plannedEndDate: _today.add(const Duration(days: 5)),
      status: TourStatus.planned,
      destinationCity: 'Pune',
      days: [
        TourDay(
          id: 'day-5',
          tourId: 'tour-2',
          planDate: _today.add(const Duration(days: 5)),
          daySeq: 1,
          activityType: DayActivity.visits,
          fromCity: 'Pune',
          toCity: 'Pune',
        ),
      ],
    ),
  ];

  static final visitPlans = <VisitPlan>[
    VisitPlan(
      id: 'plan-1',
      customerId: 'cust-1',
      customerName: 'Nagpur Distributors Pvt Ltd',
      siteId: 'site-1',
      siteName: 'Main Yard',
      visitTypeCode: 'SALES_CALL',
      plannedDate: _today,
      status: PlanStatus.planned,
      tourId: 'tour-1',
      tourDayId: 'day-2',
      plannedStartTime: '10:00',
      seq: 1,
      objective: 'Q4 volumes and scheme discussion',
      contactId: 'contact-1',
    ),
    VisitPlan(
      id: 'plan-2',
      customerId: 'cust-4',
      customerName: 'Vidarbha Traders',
      siteId: 'site-4',
      siteName: 'Shop',
      visitTypeCode: 'NEW_PROSPECT',
      plannedDate: _today,
      status: PlanStatus.planned,
      tourId: 'tour-1',
      tourDayId: 'day-2',
      plannedStartTime: '14:30',
      seq: 2,
      objective: 'First meeting — assess potential',
    ),
    VisitPlan(
      id: 'plan-3',
      customerId: 'cust-1',
      customerName: 'Nagpur Distributors Pvt Ltd',
      siteId: 'site-1b',
      siteName: 'City Warehouse',
      visitTypeCode: 'COLLECTION',
      plannedDate: _today.add(const Duration(days: 1)),
      status: PlanStatus.planned,
      tourId: 'tour-1',
      tourDayId: 'day-3',
      plannedStartTime: '11:00',
      seq: 1,
      objective: 'Collect outstanding against INV/26/8891',
    ),
    VisitPlan(
      id: 'plan-4',
      customerId: 'cust-2',
      customerName: 'Kothrud Hardware Stores',
      siteId: 'site-2',
      siteName: 'Shop',
      visitTypeCode: 'SALES_CALL',
      plannedDate: _today.add(const Duration(days: 5)),
      status: PlanStatus.planned,
      tourId: 'tour-2',
      tourDayId: 'day-5',
      plannedStartTime: '10:30',
      seq: 1,
    ),
  ];

  static final visits = <Visit>[
    Visit(
      id: 'visit-past-1',
      customerId: 'cust-2',
      customerName: 'Kothrud Hardware Stores',
      siteId: 'site-2',
      siteName: 'Shop',
      visitTypeCode: 'SALES_CALL',
      checkInAt: _at(-8, 10, 12),
      checkOutAt: _at(-8, 11, 4),
      status: VisitStatus.reportSubmitted,
      checkInPoint: const GeoPoint(18.5074, 73.8077),
      checkInDistanceM: 18,
      checkInMethod: CheckInMethod.geofence,
      tourId: null,
    ),
    Visit(
      id: 'visit-past-2',
      customerId: 'cust-3',
      customerName: 'Baner Trading Company',
      siteId: 'site-3',
      siteName: 'Main Store',
      visitTypeCode: 'COURTESY',
      checkInAt: _at(-6, 15, 30),
      checkOutAt: _at(-6, 16, 5),
      status: VisitStatus.reportSubmitted,
      checkInPoint: const GeoPoint(18.5644, 73.7772),
      checkInDistanceM: 210,
      checkInMethod: CheckInMethod.manual,
      isOutOfGeofence: true,
      outOfFenceReasonCode: 'WRONG_LOCATION_ON_FILE',
      outOfFenceRemark: 'Shop has moved two doors down; captured new location.',
    ),
  ];

  static final expenses = <Expense>[
    Expense(
      id: 'exp-1',
      categoryCode: 'TRAVEL_RAIL',
      expenseDate: _today.subtract(const Duration(days: 1)),
      amount: 2450,
      status: ExpenseStatus.submitted,
      tourId: 'tour-1',
      paymentMode: 'UPI',
      merchantName: 'IRCTC',
      paymentRef: '42139910',
      fromPlace: 'Pune',
      toPlace: 'Nagpur',
      captureSource: CaptureSource.shareIntent,
      sourceApp: 'com.google.android.apps.nbu.paisa.user',
      submittedAt: _at(-1, 19, 10),
      xinfoStatus: 'PENDING',
    ),
    Expense(
      id: 'exp-2',
      categoryCode: 'MEALS',
      expenseDate: _today,
      amount: 260,
      status: ExpenseStatus.draft,
      tourId: 'tour-1',
      paymentMode: 'CASH',
      merchantName: 'Station canteen',
    ),
    Expense(
      id: 'exp-3',
      categoryCode: 'TRAVEL_TAXI',
      expenseDate: _today.subtract(const Duration(days: 8)),
      amount: 380,
      status: ExpenseStatus.pushed,
      paymentMode: 'UPI',
      merchantName: 'Ola Cabs',
      xinfoStatus: 'APPROVED',
      settledAmount: 380,
      submittedAt: _at(-8, 18, 0),
    ),
  ];

  // ------------------------------------------------------------------ journey

  static final journeyEvents = <JourneyEvent>[
    JourneyEvent(
      id: 'je-1',
      type: JourneyEventType.departHome,
      occurredAt: _at(-1, 18, 40),
      status: EventStatus.confirmed,
      point: const GeoPoint(18.5204, 73.8567),
      placeName: 'Home',
      method: 'GEOFENCE',
      confidence: 0.95,
    ),
    JourneyEvent(
      id: 'je-2',
      type: JourneyEventType.overnightStopStart,
      occurredAt: _at(-1, 22, 15),
      status: EventStatus.detected,
      placeName: 'On train',
      method: 'DWELL',
      confidence: 0.8,
    ),
    JourneyEvent(
      id: 'je-3',
      type: JourneyEventType.arriveCustomer,
      // Low confidence on purpose: the "needs review" path is worth seeing in the UI.
      occurredAt: _at(0, 10, 5),
      status: EventStatus.needsReview,
      point: const GeoPoint(21.1458, 79.0882),
      placeName: 'Main Yard',
      customerId: 'cust-1',
      method: 'PING_CLUSTER',
      confidence: 0.62,
    ),
  ];

  static final journeySegments = <JourneySegment>[
    JourneySegment(
      id: 'seg-1',
      type: 'OUTBOUND_TRAVEL',
      startedAt: _at(-1, 18, 40),
      endedAt: _at(0, 5, 40),
      distanceM: 618000,
      travelMode: TravelMode.rail,
    ),
    JourneySegment(
      id: 'seg-2',
      type: 'INTER_TRAVEL',
      startedAt: _at(0, 9, 30),
      endedAt: _at(0, 10, 5),
      distanceM: 38000,
      travelMode: TravelMode.car,
    ),
  ];
}
