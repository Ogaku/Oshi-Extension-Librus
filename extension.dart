// @id PROVGUID-RGLR-PROV-LIBR-LIBRSYNERGIA
// @name Librus Synergia
// @version 1.2.1
// @lang pl
// @author Ogaku
// @icon https://api.librus.pl/images/logo-synergia.png
// @banner https://api.librus.pl/images/logo-synergia.png
// @baseUrl https://synergia.librus.pl
// @loginType 2
// @description /Providers/Librus/Description

import 'dart:convert';
import 'dart:math';
import 'package:oshi/bridge_lib.dart';

class LibrusSynergiaExtension extends OProvider {
  LibrusSynergiaExtension({required this.source})
      : _http = OHttpClient(
          defaultHeaders: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        );

  final OSource source;
  final OHttpClient _http;
  OProtocolDriver? _sampleDriver;

  static const String _portalRodzinaUri = 'https://synergia.librus.pl/loguj/portalRodzina';
  static const String _oauthUri = 'https://api.librus.pl/OAuth/Authorization?client_id=46';
  static const String _oauthGrantUri = 'https://api.librus.pl/OAuth/Authorization/Grant?client_id=46';
  static const String _gatewayBase = 'https://synergia.librus.pl/gateway/api/2.0';
  static const String _messagesActivationUri = 'https://synergia.librus.pl/wiadomosci3';
  static const String _messagesBase = 'https://wiadomosci.librus.pl/api';

  String _username = '';
  String _password = '';
  bool _loggedIn = false;
  final Map<String, dynamic> _registerData = <String, dynamic>{};

  @override
  String get providerName => source.name;

  @override
  String get providerDescription => source.description;

  @override
  String get providerBannerUrl => source.bannerUrl ?? source.iconUrl;

  String _makeBannerHeader() {
    String shiftChars(String raw) {
      final buf = StringBuffer();
      for (var i = 0; i < raw.length; i++) {
        buf.writeCharCode(raw.codeUnitAt(i) + 20);
      }
      return buf.toString();
    }

    final rand = Random().nextDouble().toString();
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    return '${shiftChars(rand)}_${shiftChars(now)}';
  }

  String _encodeForm(Map<String, String> fields) {
    return fields.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  String _normalizeGatewayEndpoint(String endpoint) {
    var clean = endpoint.trim();
    if (clean.startsWith('https://api.librus.pl/2.0/')) {
      clean = clean.substring('https://api.librus.pl/2.0/'.length);
    } else if (clean.startsWith('https://synergia.librus.pl/gateway/api/2.0/')) {
      clean = clean.substring('https://synergia.librus.pl/gateway/api/2.0/'.length);
    }
    while (clean.startsWith('/')) {
      clean = clean.substring(1);
    }
    return clean;
  }

  String _normalizeMessagesEndpoint(String endpoint) {
    var clean = endpoint.trim();
    while (clean.startsWith('/')) {
      clean = clean.substring(1);
    }
    return clean;
  }

  Future<void> _activateMessagesSession() async {
    var res = await _http.get(
      _messagesActivationUri,
      headers: const {'Referer': 'https://synergia.librus.pl/uczen/index'},
      followRedirects: true,
    );

    // Handle auto-submit HTML SSO forms or JS window.location redirects if present
    for (var step = 0; step < 3; step++) {
      final body = res.body;
      final curUrl = res.url.isNotEmpty ? res.url : _messagesActivationUri;
      final formMatch = RegExp(
        r'''<form[^>]*action=['"]([^'"]+)['"][^>]*>([\s\S]*?)</form>''',
        caseSensitive: false,
      ).firstMatch(body);

      if (formMatch != null) {
        final actionRaw = formMatch.group(1) ?? '';
        final formHtml = formMatch.group(2) ?? '';
        if (actionRaw.isNotEmpty) {
          final targetUrl = Uri.parse(curUrl).resolve(actionRaw).toString();
          final inputs = <String, String>{};
          for (final inp in RegExp(r'<input[^>]*>', caseSensitive: false).allMatches(formHtml)) {
            final tag = inp.group(0) ?? '';
            final nameMatch = RegExp(r'''name=['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(tag);
            if (nameMatch == null) continue;
            final valMatch = RegExp(r'''value=['"]([^'"]*)['"]''', caseSensitive: false).firstMatch(tag);
            inputs[nameMatch.group(1)!] = (valMatch?.group(1) ?? '')
                .replaceAll('&amp;', '&')
                .replaceAll('&quot;', '"');
          }
          res = await _http.post(
            targetUrl,
            body: _encodeForm(inputs),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Referer': curUrl,
            },
            followRedirects: true,
          );
          continue;
        }
      }

      final jsLocMatch = RegExp(
        r'''window\.location(?:\.href)?\s*=\s*['"]([^'"]+)['"]''',
        caseSensitive: false,
      ).firstMatch(body);
      if (jsLocMatch != null) {
        final next = jsLocMatch.group(1) ?? '';
        if (next.isNotEmpty) {
          final targetUrl = Uri.parse(curUrl).resolve(next).toString();
          res = await _http.get(
            targetUrl,
            headers: {'Referer': curUrl},
            followRedirects: true,
          );
          continue;
        }
      }
      break;
    }
  }

  Future<void> _setupToken({bool reportUi = true}) async {
    _http.clearCookies();
    if (reportUi) {
      reportProgress(0.25, localized('55E2F1C8-AD9E-4D3B-B700-0DB1493C8B07'));
    }

    var loginUrl = _oauthUri;
    try {
      var curUrl = _portalRodzinaUri;
      var referer = 'https://portal.librus.pl/';
      for (var hop = 0; hop < 5; hop++) {
        final res = await _http.get(
          curUrl,
          headers: {'Referer': referer},
          followRedirects: false,
        );
        final loc = res.location;
        if (loc == null || loc.isEmpty) {
          if (res.url.isNotEmpty) loginUrl = res.url;
          break;
        }
        final base = res.url.isNotEmpty ? res.url : curUrl;
        final nextUrl = Uri.parse(base).resolve(loc).toString();
        loginUrl = nextUrl;
        referer = base;
        curUrl = nextUrl;
      }
    } catch (_) {}

    if (reportUi) {
      reportProgress(0.35, localized('55E2F1C8-AD9E-4D3B-B700-0DB1493C8B07'));
    }

    // Prime authorization form cookies
    try {
      final primeRes = await _http.get(
        loginUrl,
        headers: const {'Referer': _portalRodzinaUri},
        followRedirects: true,
      );
      if (primeRes.url.isNotEmpty) {
        loginUrl = primeRes.url;
      }
    } catch (_) {}

    if (reportUi) {
      reportProgress(0.45, localized('C8C69498-3A64-4560-A275-3ACDCCCF1B90'));
    }

    // Post credentials to OAuth login endpoint
    final loginRes = await _http.post(
      loginUrl,
      body: _encodeForm({
        'action': 'login',
        'login': _username,
        'pass': _password,
      }),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-baner': _makeBannerHeader(),
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'Referer': loginUrl,
        'Origin': 'https://api.librus.pl',
      },
      followRedirects: false,
    );

    final loginJson = loginRes.json;
    String? nextTarget = loginRes.location;
    if (loginJson is Map) {
      if (loginJson['status'] == 'error') {
        String? errMsg;
        final errors = loginJson['errors'];
        if (errors is List && errors.isNotEmpty && errors[0] is Map) {
          errMsg = errors[0]['message']?.toString();
        }
        throw Exception(errMsg ?? 'Nieprawidłowy login i/lub hasło.');
      }
      if (nextTarget == null || nextTarget.isEmpty) {
        nextTarget = loginJson['goTo']?.toString();
      }
    }

    if (reportUi) {
      reportProgress(0.55, localized('9A7C2236-A7DC-4668-81F2-FEF1FF9B0AAE'));
    }

    // Follow continuation redirects resolving each relative Location against the hop's own URL
    var currentTarget =
        (nextTarget != null && nextTarget.isNotEmpty) ? nextTarget : '/OAuth/Authorization/2FA?client_id=46';
    var absTarget = Uri.parse(loginUrl).resolve(currentTarget).toString();
    for (var hop = 0; hop < 12; hop++) {
      final hopRes = await _http.get(
        absTarget,
        headers: {'Referer': loginUrl},
        followRedirects: false,
      );
      final loc = hopRes.location;
      if (loc == null || loc.isEmpty) break;
      final hopBase = hopRes.url.isNotEmpty ? hopRes.url : absTarget;
      absTarget = Uri.parse(hopBase).resolve(loc).toString();
    }

    // Gateway API activation
    if (reportUi) {
      reportProgress(0.65, localized('41D4096F-11CA-4385-8191-436DB9BF8A07'));
    }

    var tokenRes = await _http.get('$_gatewayBase/Auth/TokenInfo');
    var tokenJson = tokenRes.json;
    var userIdentifier = tokenJson is Map ? tokenJson['UserIdentifier'] : null;

    if (userIdentifier == null) {
      // Fallback for accounts requiring explicit Grant traversal
      await _http.get(_oauthGrantUri, headers: {'Referer': loginUrl}, followRedirects: true);
      tokenRes = await _http.get('$_gatewayBase/Auth/TokenInfo');
      tokenJson = tokenRes.json;
      userIdentifier = tokenJson is Map ? tokenJson['UserIdentifier'] : null;
    }

    if (userIdentifier == null) {
      throw Exception(localized('64D1FFB7-0CF9-43D1-8B74-998F2AB6CAA6'));
    }

    if (reportUi) {
      reportProgress(0.75, localized('5DA166B8-F9B9-40A1-8E90-22ED84E498A3'));
    }

    final authRes = await _http.get('$_gatewayBase/Auth/UserInfo/$userIdentifier');
    final authJson = authRes.json;
    if (authJson is! Map || authJson['UserState'] != 'ACTIVE') {
      throw Exception(localized('64D1FFB7-0CF9-43D1-8B74-998F2AB6CAA6'));
    }

    // Activate messages SSO session (hop-by-hop cookies preserved per domain)
    if (reportUi) {
      reportProgress(0.85, localized('FB716D2D-FFFA-41C5-91B5-02678F6D0FA5'));
    }
    await _activateMessagesSession();

    if (reportUi) {
      reportProgress(0.95, localized('4D52E8BC-6C25-4C8F-B031-777844C73315'));
    }
    await Future.delayed(const Duration(milliseconds: 250));
    _loggedIn = true;
  }

  Future<Map<String, dynamic>> _apiGet(String endpoint) async {
    final url = '$_gatewayBase/${_normalizeGatewayEndpoint(endpoint)}';
    var res = await _http.get(url);
    if (res.statusCode == 401 || res.statusCode == 403 || res.json is! Map) {
      if (_username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.get(url);
      }
    }
    final parsed = res.json;
    if (parsed is Map) {
      return parsed.cast<String, dynamic>();
    }
    throw Exception('Synergia gateway error (${res.statusCode}) on $endpoint');
  }

  Future<Map<String, dynamic>> _apiPost(String endpoint, Object data) async {
    final url = '$_gatewayBase/${_normalizeGatewayEndpoint(endpoint)}';
    final bodyStr = data is String ? data : jsonEncode(data);
    var res = await _http.post(
      url,
      body: bodyStr,
      headers: const {'Content-Type': 'application/json'},
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      if (_username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.post(
          url,
          body: bodyStr,
          headers: const {'Content-Type': 'application/json'},
        );
      }
    }
    final parsed = res.json;
    if (parsed is Map) return parsed.cast<String, dynamic>();
    if (res.statusCode >= 200 && res.statusCode < 300) return <String, dynamic>{};
    throw Exception('Synergia gateway POST error (${res.statusCode}) on $endpoint');
  }

  Future<String> _synergiaGet(String endpoint) async {
    final clean = endpoint.startsWith('/') ? endpoint.substring(1) : endpoint;
    final url = 'https://synergia.librus.pl/$clean';
    var res = await _http.get(url);
    if (res.statusCode == 401 || res.statusCode == 403 || res.url.contains('/loguj')) {
      if (_username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.get(url);
      }
    }
    return res.body;
  }

  Future<Map<String, dynamic>> _messagesGet(String endpoint) async {
    if (_http.getCookies('https://wiadomosci.librus.pl').isEmpty) {
      await _activateMessagesSession();
    }
    final url = '$_messagesBase/${_normalizeMessagesEndpoint(endpoint)}';
    var res = await _http.get(
      url,
      headers: const {
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://wiadomosci.librus.pl/',
      },
    );

    if (res.statusCode == 401 ||
        res.statusCode == 403 ||
        res.url.contains('loguj') ||
        res.url.contains('OAuth') ||
        res.json is! Map) {
      await _activateMessagesSession();
      res = await _http.get(
        url,
        headers: const {
          'Accept': 'application/json, text/plain, */*',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': 'https://wiadomosci.librus.pl/',
        },
      );

      if ((res.statusCode == 401 || res.statusCode == 403 || res.json is! Map) &&
          _username.isNotEmpty &&
          _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.get(
          url,
          headers: const {
            'Accept': 'application/json, text/plain, */*',
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': 'https://wiadomosci.librus.pl/',
          },
        );
      }
    }

    final parsed = res.json;
    if (parsed is Map) {
      return parsed.cast<String, dynamic>();
    }
    throw Exception('Messages API error (${res.statusCode}) on $endpoint');
  }

  Future<Map<String, dynamic>> _messagesPost(String endpoint, Object data) async {
    if (_http.getCookies('https://wiadomosci.librus.pl').isEmpty) {
      await _activateMessagesSession();
    }
    final url = '$_messagesBase/${_normalizeMessagesEndpoint(endpoint)}';
    final bodyStr = data is String ? data : jsonEncode(data);
    var res = await _http.post(
      url,
      body: bodyStr,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://wiadomosci.librus.pl/',
      },
    );

    if (res.statusCode == 401 || res.statusCode == 403 || res.json is! Map) {
      await _activateMessagesSession();
      res = await _http.post(
        url,
        body: bodyStr,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/plain, */*',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': 'https://wiadomosci.librus.pl/',
        },
      );
      if ((res.statusCode == 401 || res.statusCode == 403 || res.json is! Map) &&
          _username.isNotEmpty &&
          _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.post(
          url,
          body: bodyStr,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/plain, */*',
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': 'https://wiadomosci.librus.pl/',
          },
        );
      }
    }

    final parsed = res.json;
    if (parsed is Map) return parsed.cast<String, dynamic>();
    throw Exception('Messages POST error (${res.statusCode}) on $endpoint');
  }

  Future<void> _messagesDelete(String endpoint) async {
    if (_http.getCookies('https://wiadomosci.librus.pl').isEmpty) {
      await _activateMessagesSession();
    }
    final url = '$_messagesBase/${_normalizeMessagesEndpoint(endpoint)}';
    var res = await _http.delete(
      url,
      headers: const {
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://wiadomosci.librus.pl/',
      },
    );

    if (res.statusCode == 401 || res.statusCode == 403) {
      await _activateMessagesSession();
      res = await _http.delete(
        url,
        headers: const {
          'Accept': 'application/json, text/plain, */*',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': 'https://wiadomosci.librus.pl/',
        },
      );
      if ((res.statusCode == 401 || res.statusCode == 403) &&
          _username.isNotEmpty &&
          _password.isNotEmpty) {
        await _setupToken(reportUi: false);
        res = await _http.delete(
          url,
          headers: const {
            'Accept': 'application/json, text/plain, */*',
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': 'https://wiadomosci.librus.pl/',
          },
        );
      }
    }

    if (res.statusCode >= 400) {
      throw Exception('Messages DELETE error (${res.statusCode}) on $endpoint');
    }
  }

  // --- Safe JSON helpers ---

  String _str(dynamic v, [String def = '']) {
    if (v == null) return def;
    return v.toString();
  }

  int _int(dynamic v, [int def = -1]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v == null) return def;
    return int.tryParse(v.toString().trim()) ?? def;
  }

  int? _intOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  bool _bool(dynamic v, [bool def = false]) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final low = v.trim().toLowerCase();
      if (low == 'true' || low == '1') return true;
      if (low == 'false' || low == '0') return false;
    }
    return def;
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is Map) out.add(item.cast<String, dynamic>());
    }
    return out;
  }

  DateTime? _parseDateTime(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    var s = v.toString().trim();
    if (s.isEmpty || s.startsWith('0000-00-00')) return null;
    if (s.length >= 19 && s[10] == ' ') {
      s = '${s.substring(0, 10)}T${s.substring(11)}';
    }
    return DateTime.tryParse(s);
  }

  String _dateIso(dynamic v) => (_parseDateTime(v) ?? DateTime.now()).toIso8601String();

  String? _dateIsoOrNull(dynamic v) => _parseDateTime(v)?.toIso8601String();

  DateTime _parseTimeOnDate(String? timeStr, [DateTime? baseDate]) {
    final d = baseDate ?? DateTime(2000);
    if (timeStr == null || timeStr.trim().isEmpty) {
      return DateTime(d.year, d.month, d.day);
    }
    final parts = timeStr.trim().split(':');
    final h = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final s = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
    return DateTime(d.year, d.month, d.day, h, m, s);
  }

  String _tryBase64Decode(dynamic raw) {
    if (raw == null) return '';
    final str = raw.toString().trim();
    if (str.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(str));
    } catch (_) {
      return str;
    }
  }

  bool _sameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isSameOrAfterDay(DateTime day, DateTime bound) {
    final d = DateTime(day.year, day.month, day.day);
    final b = DateTime(bound.year, bound.month, bound.day);
    return !d.isBefore(b);
  }

  bool _isSameOrBeforeDay(DateTime day, DateTime bound) {
    final d = DateTime(day.year, day.month, day.day);
    final b = DateTime(bound.year, bound.month, bound.day);
    return !d.isAfter(b);
  }

  String _ymd(DateTime d) => '${d.year}-${d.month}-${d.day}';

  String _attendanceTypeString(int id) {
    switch (id) {
      case 1:
        return 'absent';
      case 2:
        return 'late';
      case 3:
        return 'excused';
      case 4:
        return 'duty';
      case 100:
        return 'present';
      default:
        return 'absent';
    }
  }

  String? _eventCategoryString(int id) {
    switch (id) {
      case 10839:
        return 'gathering';
      case 10840:
        return 'lecture';
      case 11093:
        return 'test';
      case 11094:
        return 'classWork';
      case 11715:
        return 'semCorrection';
      case 11716:
        return 'other';
      case 11717:
        return 'lessonWork';
      case 11853:
        return 'shortTest';
      case 15753:
        return 'correction';
      case 17337:
        return 'onlineLesson';
      default:
        return null;
    }
  }

  Map<String, dynamic> _teacherToJson(
    Map<String, dynamic> user, {
    int? homeTeacherId,
    int? resolvedUserId,
  }) {
    final id = _int(user['Id']);
    final effectiveUserId = resolvedUserId ?? _intOrNull(user['UserId']);
    return {
      'id': id,
      if (effectiveUserId != null) 'userId': effectiveUserId,
      'url': '',
      'firstName': _str(user['FirstName']),
      'lastName': _str(user['LastName']),
      'isHomeTeacher': homeTeacherId != null && id == homeTeacherId,
    };
  }

  Map<String, dynamic> _subjectToJson(Map<String, dynamic> subj) {
    return {
      'id': _int(subj['Id']),
      'url': '',
      'name': _str(subj['Name'], 'Unknown'),
      'no': _int(subj['No'], 0),
      'short': _str(subj['Short'], 'Unknwn'),
      'isExtracurricular': _bool(subj['IsExtracurricular']),
      'isBlockLesson': _bool(subj['IsBlockLesson']),
    };
  }

  Map<String, dynamic> _classroomToJson(Map<String, dynamic> room) {
    return {
      'id': _int(room['Id']),
      'url': '',
      'name': _str(room['Name']),
      'symbol': _str(room['Symbol']),
    };
  }

  String _teacherInvName(Map<String, dynamic> user) {
    final f = _str(user['FirstName']);
    final l = _str(user['LastName']);
    if (f.isEmpty && l.isEmpty) return 'Unknown';
    if (f.isEmpty) return l;
    return l.isEmpty ? f : '$l $f';
  }

  String _teacherFwdName(Map<String, dynamic> user) {
    final f = _str(user['FirstName']);
    final l = _str(user['LastName']);
    if (f.isEmpty && l.isEmpty) return 'Unknown';
    if (f.isEmpty) return l;
    return l.isEmpty ? f : '$f $l';
  }

  String _firstLetters(String s) {
    final buf = StringBuffer();
    for (final part in s.split(' ')) {
      if (part.isNotEmpty) buf.write(part[0].toLowerCase());
    }
    return buf.toString();
  }

  Map<String, dynamic>? _findById(List<Map<String, dynamic>> items, int id, {String key = 'Id'}) {
    if (id < 0) return null;
    for (final item in items) {
      if (_int(item[key]) == id) return item;
    }
    return null;
  }

  Future<Map<String, int>> _loadMessageUserIds() async {
    final userIdToAccountId = <String, int>{};
    final result = <String, int>{};
    try {
      final resp = await _messagesGet('receivers/groups/school-employees');
      final rawList = resp['receivers'] ?? resp['data'];
      for (final rec in _mapList(rawList)) {
        final uid = _intOrNull(rec['userId']);
        final aid = _intOrNull(rec['accountId']);
        if (uid != null && aid != null) {
          userIdToAccountId[uid.toString()] = aid;
          result[uid.toString()] = aid;
        }
      }
    } catch (_) {}
    return userIdToAccountId;
  }

  Future<String> _unwrapLinksAndMessageBody(String rawBase64) async {
    var content = _tryBase64Decode(rawBase64)
        .replaceAll('<Message><Content><![CDATA[', '')
        .replaceAll(']]></Content><Actions><Actions/></Actions></Message>', '')
        .trim();

    final matches = RegExp('(?<=systemu.">)(.*?)(?=</a>)').allMatches(content).toList();
    for (final match in matches) {
      var link = match.group(0) ?? '';
      if (link.isNotEmpty && link.startsWith('https://liblink.pl/')) {
        try {
          final res = await _http.post(link, followRedirects: false);
          final loc = res.location;
          if (loc != null && loc.isNotEmpty) link = loc;
        } catch (_) {}
      }
      content = content.replaceFirst(RegExp('<a href="(.*?)</a>'), link);
    }
    return content;
  }

  // --- OProvider Lifecycle Methods ---

  @override
  Future<Map<String, dynamic>> login(Map<String, String> credentials) async {
    reportProgress(0.1, localized('D870CFEB-F16B-4091-9084-9620E5BACE22'));
    _username = (credentials['login'] ?? '').trim();
    _password = credentials['pass'] ?? '';

    final lowUser = _username.toLowerCase();
    if ((lowUser == 'test' && _password == 'test') || (lowUser == 'demo' && _password == 'demo')) {
      _sampleDriver ??= OProtocolDriver('sample');
      return await _sampleDriver!.login(credentials);
    }
    _sampleDriver = null;

    if (_username.isEmpty || _password.isEmpty) {
      return {
        'success': false,
        'message': localized('E15B042C-B7C1-43AB-9557-EA1B1F08CE9C'),
      };
    }

    reportProgress(0.2, localized('440FA18A-AD7D-47B4-B4FF-C2FE934479DA'));
    try {
      await _setupToken(reportUi: true);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> refresh(String? weekStartIso) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.refresh(weekStartIso);
    }

    try {
      if (!_loggedIn) {
        if (_username.isEmpty || _password.isEmpty) {
          return {'success': false, 'message': localized('C5FDD0D8-771D-4DCE-8FCE-62D1BA4A6C93')};
        }
        await _setupToken(reportUi: false);
      }

      final lessonsList = _mapList((await _apiGet('Lessons'))['Lessons']);
      final subjectsList = _mapList((await _apiGet('Subjects'))['Subjects']);
      final teachersList = _mapList((await _apiGet('Users'))['Users']);
      final classroomsList = _mapList((await _apiGet('Classrooms'))['Classrooms']);
      final gradeCategories = _mapList((await _apiGet('Grades/Categories'))['Categories']);
      final gradeComments = _mapList((await _apiGet('Grades/Comments'))['Comments']);
      final eventCategories = _mapList((await _apiGet('HomeWorks/Categories'))['Categories']);
      final freeDayTypes = _mapList((await _apiGet('ClassFreeDays/Types'))['Types']);
      final virtualClassesList = _mapList((await _apiGet('VirtualClasses'))['VirtualClasses']);
      final homeworkCategories = _mapList((await _apiGet('HomeWorkAssignments/Categories'))['Categories']);

      final DateTime? weekStart =
          (weekStartIso != null && weekStartIso.isNotEmpty) ? DateTime.tryParse(weekStartIso) : null;

      final ttPrimary = weekStart != null
          ? await _apiGet(
              'Timetables?weekStart=${_ymd(weekStart.subtract(Duration(days: weekStart.weekday - 1)))}')
          : await _apiGet('Timetables');

      final rawTimetableMap = <String, dynamic>{};
      if (ttPrimary['Timetable'] is Map) {
        (ttPrimary['Timetable'] as Map).forEach((k, v) {
          rawTimetableMap[k.toString()] = v;
        });
      }

      try {
        final baseNext = weekStart != null
            ? weekStart.add(const Duration(days: 7)).subtract(Duration(days: weekStart.weekday - 1))
            : DateTime.now()
                .add(const Duration(days: 7))
                .subtract(Duration(days: DateTime.now().weekday - 1));
        final ttNext = await _apiGet('Timetables?weekStart=${_ymd(baseNext)}');
        if (ttNext['Timetable'] is Map) {
          (ttNext['Timetable'] as Map).forEach((k, v) {
            rawTimetableMap[k.toString()] = v;
          });
        }
      } catch (_) {}

      reportProgress(0.1, localized('9395EE9D-253E-4795-9F7D-DFA49D161EA8'));

      // Attendances
      final rawAttendances = _mapList((await _apiGet('Attendances'))['Attendances']);
      final attendancesJson = <Map<String, dynamic>>[];
      for (final x in rawAttendances) {
        final lessonLink = x['Lesson'] is Map ? (x['Lesson'] as Map) : null;
        final lessonId = lessonLink != null ? _int(lessonLink['Id']) : -1;
        final lessonObj = _findById(lessonsList, lessonId);
        final subjId = (lessonObj != null && lessonObj['Subject'] is Map)
            ? _int((lessonObj['Subject'] as Map)['Id'])
            : -1;
        final subjObj = _findById(subjectsList, subjId);
        final addedById = x['AddedBy'] is Map ? _int((x['AddedBy'] as Map)['Id']) : -1;
        final teacherObj = _findById(teachersList, addedById);
        final typeId = x['Type'] is Map ? _int((x['Type'] as Map)['Id']) : 1;
        final dateIso = _dateIso(x['Date']);
        final lessonNo = _int(x['LessonNo']);

        final teacherJson = teacherObj != null ? _teacherToJson(teacherObj) : _teacherToJson({});
        attendancesJson.add({
          'id': _int(x['Id']),
          'lessonNo': lessonNo,
          'lesson': {
            'url': '',
            'lessonNo': lessonNo,
            'isCanceled': false,
            if (subjObj != null) 'subject': _subjectToJson(subjObj),
            'teacher': teacherJson,
            'modifiedSchedule': false,
            'date': dateIso,
          },
          'date': dateIso,
          'addDate': _dateIso(x['AddDate']),
          'type': _attendanceTypeString(typeId),
          'teacher': teacherJson,
        });
      }

      reportProgress(0.2, localized('4C6CC778-B7FE-4B76-BE87-BCFC9E1E2F7B'));

      // Student, Class, Unit, School
      final meMap = ((await _apiGet('Me'))['Me'] as Map?)?.cast<String, dynamic>() ?? {};
      final accountMap = (meMap['Account'] as Map?)?.cast<String, dynamic>() ?? {};
      final meClassMap = (meMap['Class'] as Map?)?.cast<String, dynamic>() ?? {};
      final classId = _int(meClassMap['Id']);

      final classResp = await _apiGet('Classes/$classId');
      final classMap = (classResp['Class'] as Map?)?.cast<String, dynamic>() ?? {};
      final unitId = classMap['Unit'] is Map ? _int((classMap['Unit'] as Map)['Id']) : -1;
      final unitResp = await _apiGet('Units/$unitId');
      final unitMap = (unitResp['Unit'] as Map?)?.cast<String, dynamic>() ?? {};
      final schoolsResp = await _apiGet('Schools');
      final schoolMap = (schoolsResp['School'] as Map?)?.cast<String, dynamic>() ?? {};

      final tutorId = classMap['ClassTutor'] is Map ? _int((classMap['ClassTutor'] as Map)['Id']) : -1;
      final homeTeacherObj = _findById(teachersList, tutorId);
      final homeTeacherJson = homeTeacherObj != null
          ? _teacherToJson(homeTeacherObj, homeTeacherId: tutorId)
          : {
              'id': -1,
              'url': '',
              'firstName': 'Unknown',
              'lastName': 'Unknown',
              'isHomeTeacher': true,
            };

      final lessonsRangeJson = <Map<String, dynamic>>[];
      for (final lr in _mapList(unitMap['LessonsRange'])) {
        lessonsRangeJson.add({
          'from': _parseTimeOnDate(_str(lr['From'], '08:00')).toIso8601String(),
          'to': _parseTimeOnDate(_str(lr['To'], '08:45')).toIso8601String(),
        });
      }

      final schoolId = _int(schoolMap['Id']);
      final schoolName = _str(schoolMap['Name']);
      final town = _str(schoolMap['Town']);
      final street = _str(schoolMap['Street']).replaceAll('ul. ', '');
      final building = _str(schoolMap['BuildingNumber']);

      int? luckyNum;
      bool luckyTomorrow = false;
      try {
        final lnResp = await _apiGet('LuckyNumbers');
        final lnMap = lnResp['LuckyNumber'] as Map?;
        if (lnMap != null) {
          final lnDay = _parseDateTime(lnMap['LuckyNumberDay']) ?? DateTime(2000);
          final now = DateTime.now();
          final forToday = _sameDate(lnDay, now);
          final forTomorrow = _sameDate(lnDay, now.add(const Duration(days: 1)));
          if (forToday || forTomorrow) {
            luckyNum = _intOrNull(lnMap['LuckyNumber']);
            if (!forToday && forTomorrow) luckyTomorrow = true;
          }
        }
      } catch (_) {}

      final unitJson = <String, dynamic>{
        'id': schoolId,
        'url': '',
        if (luckyNum != null) 'luckyNumber': luckyNum,
        'luckyNumberTomorrow': luckyTomorrow,
        'name': _str(unitMap['Name']),
        'fullName': schoolName,
        'principalName': '${_str(schoolMap['NameHeadTeacher'])} ${_str(schoolMap['SurnameHeadTeacher'])}'.trim(),
        'address': '$building $street, $town'.trim(),
        'town': town,
        'email': _str(schoolMap['Email']),
        'phone': _str(schoolMap['PhoneNumber']),
        'type': _str(unitMap['Type']),
        'behaviourType': _str(unitMap['BehaviourType']),
        'lessonsRange': lessonsRangeJson,
        'announcements': <Map<String, dynamic>>[],
      };

      final classNumber = _int(classMap['Number'], -1);
      final classSymbol = _str(classMap['Symbol']);
      final mainClassName = '$classNumber$classSymbol';
      final beginYearIso = _dateIso(classMap['BeginSchoolYear']);
      final endSem1Iso = _dateIso(classMap['EndFirstSemester']);
      final endYearIso = _dateIso(classMap['EndSchoolYear']);

      final mainClassJson = <String, dynamic>{
        'id': _int(classMap['Id']),
        'number': classNumber,
        'symbol': classSymbol,
        'name': mainClassName,
        'beginSchoolYear': beginYearIso,
        'endFirstSemester': endSem1Iso,
        'endSchoolYear': endYearIso,
        'unit': unitJson,
        'classTutor': homeTeacherJson,
        'events': <Map<String, dynamic>>[],
        'averages': <String, dynamic>{},
      };

      final virtualClassesJson = <Map<String, dynamic>>[];
      for (final vc in virtualClassesList) {
        virtualClassesJson.add({
          'id': _int(vc['Id']),
          'number': _int(vc['Number'], -1),
          'symbol': _str(vc['Symbol']),
          'name': _str(vc['Name']),
          'beginSchoolYear': beginYearIso,
          'endFirstSemester': endSem1Iso,
          'endSchoolYear': endYearIso,
          'unit': unitJson,
          'classTutor': homeTeacherJson,
          'events': <Map<String, dynamic>>[],
          'averages': <String, dynamic>{},
        });
      }

      // Collect all teacher IDs appearing in the fetched timetable to pick primary teacher per subject
      final timetableTeacherIds = <String>{};
      rawTimetableMap.forEach((_, daySlots) {
        if (daySlots is List) {
          for (final slot in daySlots) {
            if (slot is List) {
              for (final entry in slot) {
                if (entry is Map && entry['Teacher'] is Map) {
                  timetableTeacherIds.add(_str(entry['Teacher']['Id']));
                }
              }
            }
          }
        }
      });

      final lessonsBySubject = <int, List<Map<String, dynamic>>>{};
      for (final lesson in lessonsList) {
        if (lesson['Subject'] is! Map) continue;
        final sid = _int((lesson['Subject'] as Map)['Id']);
        if (sid < 0) continue;
        lessonsBySubject.putIfAbsent(sid, () => <Map<String, dynamic>>[]).add(lesson);
      }

      final studentSubjectsJson = <Map<String, dynamic>>[];
      lessonsBySubject.forEach((sid, group) {
        var chosen = group.first;
        for (final cand in group) {
          final tid = cand['Teacher'] is Map ? _str((cand['Teacher'] as Map)['Id']) : '';
          if (tid.isNotEmpty && timetableTeacherIds.contains(tid)) {
            chosen = cand;
            break;
          }
        }
        final subjUrl = chosen['Subject'] is Map ? _str((chosen['Subject'] as Map)['Url']) : '';
        final subjObj = _findById(subjectsList, sid);
        final tid = chosen['Teacher'] is Map ? _int((chosen['Teacher'] as Map)['Id']) : -1;
        final teacherObj = _findById(teachersList, tid);
        studentSubjectsJson.add({
          'id': sid,
          'url': subjUrl,
          'name': _str(subjObj?['Name'], 'Unknown'),
          'no': _int(subjObj?['No'], 0),
          'short': _str(subjObj?['Short'], 'Unknwn'),
          'isExtracurricular': _bool(subjObj?['IsExtracurricular']),
          'isBlockLesson': _bool(subjObj?['IsBlockLesson']),
          'hostClass': mainClassJson,
          if (teacherObj != null) 'teacher': _teacherToJson(teacherObj, homeTeacherId: tutorId),
          'grades': <Map<String, dynamic>>[],
        });
      });

      int regNumber = 0;
      final accountUserId = _int(accountMap['UserId']);
      try {
        final userDetail = await _apiGet('Users/$accountUserId');
        if (userDetail['User'] is Map) {
          regNumber = _int(userDetail['User']['ClassRegisterNumber'], 0);
        }
      } catch (_) {}

      final teamPrefix = '${schoolId}${_firstLetters(schoolName)}_$town:'.toLowerCase();
      final teamCodes = <String, String>{
        '$teamPrefix$mainClassName'.toLowerCase(): mainClassName,
      };
      for (final vc in virtualClassesJson) {
        final vcName = _str(vc['name']).isNotEmpty ? _str(vc['name']) : _str(vc['symbol']);
        teamCodes['$teamPrefix$vcName'.toLowerCase()] = vcName;
      }

      reportProgress(0.3, localized('65F39C72-B55D-4970-986B-69DDA8135FF7'));

      // Timetables
      final timetableDaysJson = <String, dynamic>{};
      final dayDatesByKey = <String, DateTime>{};

      rawTimetableMap.forEach((dateKey, rawSlots) {
        final parsedDay = DateTime.tryParse(dateKey);
        if (parsedDay == null) return;
        final dayIso = parsedDay.toIso8601String();
        dayDatesByKey[dayIso] = parsedDay;

        final outSlots = <List<Map<String, dynamic>>?>[];
        if (rawSlots is List) {
          for (final slotRaw in rawSlots) {
            if (slotRaw is! List) {
              outSlots.add(null);
              continue;
            }
            final slotLessons = <Map<String, dynamic>>[];
            for (final item in slotRaw) {
              if (item is! Map) continue;
              final lesson = item.cast<String, dynamic>();
              final isSub = _bool(lesson['IsSubstitutionClass']);
              final isCanceled = _bool(lesson['IsCanceled']);
              final lessonLink = lesson['Lesson'] is Map ? (lesson['Lesson'] as Map) : null;
              final lessonClassMap = lesson['Class'] is Map ? (lesson['Class'] as Map) : null;
              final vcMap = lesson['VirtualClass'] is Map ? (lesson['VirtualClass'] as Map) : null;
              final roomMap = lesson['Classroom'] is Map ? (lesson['Classroom'] as Map) : null;
              final subjMap = lesson['Subject'] is Map ? (lesson['Subject'] as Map) : null;
              final teacherMap = lesson['Teacher'] is Map ? (lesson['Teacher'] as Map) : null;

              Map<String, dynamic>? resolvedLessonClass;
              if (lessonClassMap != null && _int(lessonClassMap['Id']) == _int(mainClassJson['id'])) {
                resolvedLessonClass = mainClassJson;
              } else if (vcMap != null) {
                final vcId = _int(vcMap['Id']);
                for (final vc in virtualClassesJson) {
                  if (_int(vc['id']) == vcId) {
                    resolvedLessonClass = vc;
                    break;
                  }
                }
              }

              final roomObj = _findById(classroomsList, _int(roomMap?['Id']));
              final subjObj = _findById(subjectsList, _int(subjMap?['Id']));
              final tObj = _findById(teachersList, _int(teacherMap?['Id']));

              Map<String, dynamic>? subDetails;
              if (isSub) {
                final orgDate = _parseDateTime(lesson['OrgDate']);
                final newDate = _parseDateTime(lesson['NewDate']);
                final refDate = orgDate ?? newDate ?? DateTime.now();

                final orgHourFromStr = lesson['OrgHourFrom']?.toString();
                final newHourFromStr = lesson['NewHourFrom']?.toString();
                final orgHourToStr = lesson['OrgHourTo']?.toString();
                final newHourToStr = lesson['NewHourTo']?.toString();

                final orgRoomId = _int((lesson['OrgClassroom'] as Map?)?['Id']);
                final newRoomId = _int((lesson['NewClassroom'] as Map?)?['Id']);
                final subRoomObj = _findById(classroomsList, orgRoomId >= 0 ? orgRoomId : newRoomId);

                final orgSubjId = _int((lesson['OrgSubject'] as Map?)?['Id']);
                final newSubjId = _int((lesson['NewSubject'] as Map?)?['Id']);
                final subSubjObj = _findById(subjectsList, orgSubjId >= 0 ? orgSubjId : newSubjId);

                final orgTId = _int((lesson['OrgTeacher'] as Map?)?['Id']);
                final newTId = _int((lesson['NewTeacher'] as Map?)?['Id']);
                final subTObj = _findById(teachersList, orgTId >= 0 ? orgTId : newTId);

                subDetails = {
                  'originalUrl': '',
                  'originalLessonNo':
                      _intOrNull(lesson['OrgLessonNo']) ?? _intOrNull(lesson['NewLessonNo']) ?? 0,
                  'originalDate': refDate.toIso8601String(),
                  'originalHourFrom': (orgHourFromStr != null
                          ? _parseTimeOnDate(orgHourFromStr, orgDate)
                          : (newHourFromStr != null
                              ? _parseTimeOnDate(newHourFromStr, newDate)
                              : DateTime.now()))
                      .toIso8601String(),
                  'originalHourTo': (orgHourToStr != null
                          ? _parseTimeOnDate(orgHourToStr, orgDate)
                          : (newHourToStr != null
                              ? _parseTimeOnDate(newHourToStr, newDate)
                              : DateTime.now()))
                      .toIso8601String(),
                  if (subRoomObj != null) 'originalClassroom': _classroomToJson(subRoomObj),
                  if (subSubjObj != null) 'originalSubject': _subjectToJson(subSubjObj),
                  if (subTObj != null) 'originalTeacher': _teacherToJson(subTObj, homeTeacherId: tutorId),
                };
              }

              slotLessons.add({
                'url': _str(lessonLink?['Url']),
                'lessonNo': _int(lesson['LessonNo'], -1),
                'isCanceled': isCanceled,
                'modifiedSchedule': isSub,
                'substitutionNote': '',
                'date': dayIso,
                'hourFrom': _parseTimeOnDate(_str(lesson['HourFrom'], '00:00')).toIso8601String(),
                'hourTo': _parseTimeOnDate(_str(lesson['HourTo'], '00:00')).toIso8601String(),
                if (resolvedLessonClass != null) 'lessonClass': resolvedLessonClass,
                if (roomObj != null) 'classroom': _classroomToJson(roomObj),
                if (subjObj != null) 'subject': _subjectToJson(subjObj),
                if (tObj != null) 'teacher': _teacherToJson(tObj, homeTeacherId: tutorId),
                if (subDetails != null) 'substitutionDetails': subDetails,
              });
            }
            outSlots.add(slotLessons);
          }
        }

        timetableDaysJson[dayIso] = {'lessons': outSlots};
      });

      reportProgress(0.4, localized('8966023D-0F77-4B9D-B31B-385A201EB05A'));

      // Announcements
      final notices = _mapList((await _apiGet('SchoolNotices'))['SchoolNotices']);
      final announcementsJson = <Map<String, dynamic>>[];
      for (final n in notices) {
        final cid = _int((n['AddedBy'] as Map?)?['Id']);
        final contactObj = _findById(teachersList, cid);
        announcementsJson.add({
          'id': -1,
          'url': _str(n['Id']),
          'read': _bool(n['WasRead']),
          'subject': _str(n['Subject']),
          'content': _str(n['Content']),
          if (contactObj != null) 'contact': _teacherToJson(contactObj, homeTeacherId: tutorId),
          'startDate': _dateIso(n['StartDate']),
          'endDate': _dateIso(n['EndDate']),
        });
      }
      unitJson['announcements'] = announcementsJson;
      mainClassJson['unit'] = unitJson;

      // Events: HomeWorks, ParentTeacherConferences, HomeWorkAssignments, FreeDays
      final eventsJson = <Map<String, dynamic>>[];
      final homeWorks = _mapList((await _apiGet('HomeWorks'))['HomeWorks']);
      for (final hw in homeWorks) {
        final hwDate = _parseDateTime(hw['Date']);
        final catId = _int((hw['Category'] as Map?)?['Id']);
        final mappedCat = _eventCategoryString(catId);
        final catObj = _findById(eventCategories, catId);
        final cid = _int((hw['CreatedBy'] as Map?)?['Id']);
        final senderObj = _findById(teachersList, cid);
        final rid = _int((hw['Classroom'] as Map?)?['Id']);
        final roomObj = _findById(classroomsList, rid);

        eventsJson.add({
          'id': _int(hw['Id']),
          if (_intOrNull(hw['LessonNo']) != null) 'lessonNo': _intOrNull(hw['LessonNo']),
          if (hwDate != null) 'date': hwDate.toIso8601String(),
          if (_dateIsoOrNull(hw['AddDate']) != null) 'addDate': _dateIsoOrNull(hw['AddDate']),
          'timeFrom': _parseTimeOnDate(_str(hw['TimeFrom']), hwDate).toIso8601String(),
          'timeTo': _parseTimeOnDate(_str(hw['TimeTo']), hwDate).toIso8601String(),
          'content': _str(hw['Content']),
          'category': mappedCat ?? 'other',
          'categoryName': mappedCat == null ? _str(catObj?['Name']) : '',
          if (senderObj != null) 'sender': _teacherToJson(senderObj, homeTeacherId: tutorId),
          if (roomObj != null) 'classroom': _classroomToJson(roomObj),
        });
      }

      try {
        final ptcList =
            _mapList((await _apiGet('ParentTeacherConferences'))['ParentTeacherConferences']);
        for (final ptc in ptcList) {
          final pDate = _parseDateTime(ptc['Date']);
          final tid = _int((ptc['Teacher'] as Map?)?['Id']);
          final senderObj = _findById(teachersList, tid);
          final roomName = _str(ptc['Room']);
          Map<String, dynamic>? roomObj;
          if (roomName.isNotEmpty) {
            for (final r in classroomsList) {
              if (_str(r['Name']) == roomName) {
                roomObj = r;
                break;
              }
            }
          }
          eventsJson.add({
            'id': _int(ptc['Id']),
            if (pDate != null) 'date': pDate.toIso8601String(),
            'timeFrom': _parseTimeOnDate(_str(ptc['Time']), pDate).toIso8601String(),
            'content': _str(ptc['Topic']),
            'category': 'conference',
            'categoryName': '',
            if (senderObj != null) 'sender': _teacherToJson(senderObj, homeTeacherId: tutorId),
            if (roomObj != null) 'classroom': _classroomToJson(roomObj),
          });
        }
      } catch (_) {}

      reportProgress(0.5, localized('166B3D1B-90DF-446D-87F6-B27BF62D2C23'));

      try {
        final hwaList = _mapList((await _apiGet('HomeWorkAssignments'))['HomeWorkAssignments']);
        for (final hwa in hwaList) {
          final hwaId = _int(hwa['Id']);
          final catId = _int((hwa['Category'] as Map?)?['Id']);
          final catObj = _findById(homeworkCategories, catId);
          final tid = _int((hwa['Teacher'] as Map?)?['Id']);
          final senderObj = _findById(teachersList, tid);
          final filesRaw = hwa['HomeworkAssigmentFiles'];
          final attachments = <Map<String, dynamic>>[];
          if (filesRaw is List) {
            for (final f in filesRaw) {
              if (f is! Map) continue;
              String? url;
              try {
                final fResp = await _apiGet('HomeWorkAssignments/Attachment/$hwaId-${f['Id']}');
                url = fResp['DownloadUrl']?.toString();
                if (url != null && url.contains('GetFile')) {
                  url = '$url/get';
                }
              } catch (_) {}
              attachments.add({
                'name': f['Name']?.toString(),
                'location': url,
              });
            }
          }
          final doneList = hwa['StudentsWhoMarkedAsDone'];
          eventsJson.add({
            'id': hwaId,
            if (_dateIsoOrNull(hwa['Date']) != null) 'addDate': _dateIsoOrNull(hwa['Date']),
            'timeFrom': _dateIso(hwa['Date']),
            if (_dateIsoOrNull(hwa['DueDate']) != null) 'timeTo': _dateIsoOrNull(hwa['DueDate']),
            'title': _str(hwa['Topic']),
            'content': _str(hwa['Text']),
            'done': doneList is List && doneList.isNotEmpty,
            'category': 'homework',
            'categoryName': _str(catObj?['CategoryName']),
            if (senderObj != null) 'sender': _teacherToJson(senderObj, homeTeacherId: tutorId),
            'attachments': attachments,
          });
        }
      } catch (_) {}

      reportProgress(0.6, localized('A081AE97-83F2-4B70-98E6-1654A12455C5'));

      // SchoolFreeDays & ClassFreeDays
      try {
        final schoolFreeDays = _mapList((await _apiGet('SchoolFreeDays'))['SchoolFreeDays']);
        for (final sfd in schoolFreeDays) {
          final dFrom = _parseDateTime(sfd['DateFrom']);
          final dTo = _parseDateTime(sfd['DateTo']);
          if (dFrom == null || dTo == null) continue;
          dayDatesByKey.forEach((dayIso, dayDate) {
            if (_isSameOrAfterDay(dayDate, dFrom) && _isSameOrBeforeDay(dayDate, dTo)) {
              timetableDaysJson[dayIso] = {'lessons': <dynamic>[]};
              eventsJson.add({
                'id': _int(sfd['Id']),
                'date': dayIso,
                'timeFrom': dFrom.toIso8601String(),
                'timeTo': dTo.toIso8601String(),
                'content': _str(sfd['Name']),
                'category': 'freeDay',
                'categoryName': '',
              });
            }
          });
        }
      } catch (_) {}

      try {
        final classFreeDays = _mapList((await _apiGet('ClassFreeDays'))['ClassFreeDays']);
        final vcIds = virtualClassesJson.map((v) => _int(v['id'])).toSet();
        for (final cfd in classFreeDays) {
          final cId = _int((cfd['Class'] as Map?)?['Id']);
          final vId = _int((cfd['VirtualClass'] as Map?)?['Id']);
          if (cId != _int(mainClassJson['id']) && !vcIds.contains(vId)) continue;
          final dFrom = _parseDateTime(cfd['DateFrom']);
          final dTo = _parseDateTime(cfd['DateTo']);
          if (dFrom == null || dTo == null) continue;
          final slotFrom = _intOrNull(cfd['LessonNoFrom']) ?? 100;
          final slotTo = _intOrNull(cfd['LessonNoTo']) ?? -1;
          final typeId = _int((cfd['Type'] as Map?)?['Id']);
          final typeObj = _findById(freeDayTypes, typeId);
          final typeName = _str(typeObj?['Name']);

          dayDatesByKey.forEach((dayIso, dayDate) {
            if (_isSameOrAfterDay(dayDate, dFrom) && _isSameOrBeforeDay(dayDate, dTo)) {
              final dayMap = timetableDaysJson[dayIso];
              if (dayMap is Map && dayMap['lessons'] is List) {
                final list = dayMap['lessons'] as List;
                final keep = <dynamic>[];
                for (var idx = 0; idx < list.length; idx++) {
                  if (idx >= slotFrom && idx <= slotTo) continue;
                  keep.add(list[idx]);
                }
                dayMap['lessons'] = keep;
              }
              eventsJson.add({
                'id': _int(cfd['Id']),
                'date': dayIso,
                'timeFrom': dFrom.toIso8601String(),
                'timeTo': dTo.toIso8601String(),
                'category': 'freeDay',
                'content': typeName.isNotEmpty ? typeName : 'Lekcja odwołana',
                'categoryName': typeName,
              });
            }
          });
        }
      } catch (_) {}

      mainClassJson['events'] = eventsJson;

      reportProgress(0.7, localized('10B640EC-6CBF-42CF-A20B-7CA5E97E8AFE'));

      // Grades
      final gradesRaw = _mapList((await _apiGet('Grades'))['Grades']);
      final resitIds = <int>{};
      for (final g in gradesRaw) {
        final gid = _int(g['Id']);
        if (g['Resit'] is Map && g['Resit']['Id'] is int) {
          resitIds.add(gid);
          resitIds.add(g['Resit']['Id'] as int);
        }
        if (g['Improvement'] is Map && g['Improvement']['Id'] is int) {
          resitIds.add(gid);
          resitIds.add(g['Improvement']['Id'] as int);
        }
      }

      for (final g in gradesRaw) {
        final gid = _int(g['Id']);
        final catId = _int((g['Category'] as Map?)?['Id']);
        final catObj = _findById(gradeCategories, catId);
        final subjId = _int((g['Subject'] as Map?)?['Id']);
        final addedById = _int((g['AddedBy'] as Map?)?['Id']);
        final addedByObj = _findById(teachersList, addedById);

        final commentTexts = <String>[];
        if (g['Comments'] is List) {
          for (final cm in g['Comments'] as List) {
            if (cm is Map) {
              final cmObj = _findById(gradeComments, _int(cm['Id']));
              commentTexts.add(_str(cmObj?['Text']));
            }
          }
        }

        Map<String, dynamic>? targetSubject;
        for (final s in studentSubjectsJson) {
          if (_int(s['id']) == subjId) {
            targetSubject = s;
            break;
          }
        }
        if (targetSubject == null) continue;

        final gradeList = targetSubject['grades'] as List<Map<String, dynamic>>;
        gradeList.add({
          'id': gid,
          'url': '',
          'name': _str(catObj?['Name'], 'No category'),
          'value': _str(g['Grade']),
          'weight': _int(catObj?['Weight'], 0),
          'comments': commentTexts,
          'countsToAverage': _bool(catObj?['CountToTheAverage']),
          'date': _dateIso(g['Date']),
          'addDate': _dateIso(g['AddDate']),
          if (addedByObj != null) 'addedBy': _teacherToJson(addedByObj, homeTeacherId: tutorId),
          'resitPart': resitIds.contains(gid),
          'semester': _int(g['Semester'], -1),
          'isConstituent': _bool(g['IsConstituent']),
          'isSemester': _bool(g['IsSemester']),
          'isSemesterProposition': _bool(g['IsSemesterProposition']),
          'isFinal': _bool(g['IsFinal']),
          'isFinalProposition': _bool(g['IsFinalProposition']),
        });
      }

      // Averages chart
      try {
        final avgHtml = await _synergiaGet(
          'uczen/graph_ajax.php?type=wykres_sredniej&classId=$classId&userId=$accountUserId',
        );
        final match = RegExp(
          r'chartDataGradeAverangeGraphDiv\s*=\s*\[([\s\S]*?)\];',
        ).firstMatch(avgHtml);
        if (match != null) {
          final jsonLike = '{ ${match.group(1)} }'
              .replaceAll('{ columnGradeAverangeGraphDiv:', '')
              .replaceAll('",\n', '": {')
              .replaceAll('x0:', '"student":')
              .replaceAll('x1:', '"class":')
              .replaceAll('\n', '');
          final parsedAvg = jsonDecode(jsonLike);
          if (parsedAvg is Map) {
            final avgOut = <String, dynamic>{};
            parsedAvg.forEach((k, v) {
              if (v is Map) {
                final parts = k.toString().split('-');
                if (parts.length >= 2) {
                  final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]));
                  avgOut[dt.toIso8601String()] = {
                    'student': (v['student'] is num ? (v['student'] as num).toDouble() : 0.0),
                    'level': (v['class'] is num ? (v['class'] as num).toDouble() : 0.0),
                  };
                }
              }
            });
            mainClassJson['averages'] = avgOut;
          }
        }
      } catch (_) {}

      reportProgress(0.8, localized('3543FC9A-32FB-446F-8CB8-FEF95248CD2C'));

      final studentJson = <String, dynamic>{
        'account': {
          'id': _int(accountMap['Id']),
          'userId': accountUserId,
          'number': regNumber,
          'firstName': _str(accountMap['FirstName']),
          'lastName': _str(accountMap['LastName']),
        },
        'mainClass': mainClassJson,
        'virtualClasses': virtualClassesJson,
        'userCode': '$teamPrefix$_username'.toLowerCase(),
        'teamCodes': teamCodes,
        'attendances': attendancesJson,
        'subjects': studentSubjectsJson,
      };

      final timetablesJson = <String, dynamic>{
        'timetable': timetableDaysJson,
      };

      _registerData['student'] = studentJson;
      _registerData['timetables'] = timetablesJson;
      setRegisterDataJson({
        'student': studentJson,
        'timetables': timetablesJson,
      });

      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> refreshMessages() async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.refreshMessages();
    }

    try {
      if (!_loggedIn) {
        if (_username.isEmpty || _password.isEmpty) {
          return {'success': false, 'message': localized('C5FDD0D8-771D-4DCE-8FCE-62D1BA4A6C93')};
        }
        await _setupToken(reportUi: false);
      }

      reportProgress(0.1, localized('135991AA-5B53-42EA-8A2B-5406B249CC40'));

      final teachersList = _mapList((await _apiGet('Users'))['Users']);
      final userIdToAccount = await _loadMessageUserIds();

      final receiversJson = <Map<String, dynamic>>[];
      for (final user in teachersList) {
        final uidKey = _int(user['Id']).toString();
        final accountId = userIdToAccount[uidKey] ?? _intOrNull(user['UserId']);
        if (accountId != null) {
          user['UserId'] = accountId;
          receiversJson.add(_teacherToJson(user, resolvedUserId: accountId));
        }
      }

      reportProgress(0.9, localized('75A471A9-DA5B-4C1D-B078-6B57988F9244'));

      final receivedJson = <Map<String, dynamic>>[];
      final sentJson = <Map<String, dynamic>>[];

      Object? primaryInboxError;
      try {
        final inboxResp = await _messagesGet('inbox/messages');
        for (final x in _mapList(inboxResp['data'])) {
          final senderName = _str(x['senderName']);
          final sFirst = _str(x['senderFirstName']);
          final sLast = _str(x['senderLastName']);
          Map<String, dynamic>? matched;
          for (final u in teachersList) {
            if (_teacherInvName(u) == senderName ||
                (senderName.isNotEmpty && _teacherFwdName(u) == senderName)) {
              matched = u;
              break;
            }
          }
          final msgId = _int(x['messageId'] ?? x['MessageId'] ?? x['id']);
          final readIso = _dateIsoOrNull(x['readDate']);
          receivedJson.add({
            'id': msgId,
            'url': '',
            'topic': _str(x['topic']),
            'preview': _tryBase64Decode(x['content']),
            'hasAttachments': _bool(x['isAnyFileAttached']),
            'sendDate': _dateIso(x['sendDate']),
            if (readIso != null) 'readDate': readIso,
            'sender': matched != null
                ? _teacherToJson(matched)
                : {
                    'id': -1,
                    'url': '',
                    'firstName': sFirst.isNotEmpty ? sFirst : senderName,
                    'lastName': sLast,
                  },
          });
        }
      } catch (e) {
        primaryInboxError = e;
      }

      try {
        final outboxResp = await _messagesGet('outbox/messages');
        for (final x in _mapList(outboxResp['data'])) {
          final receiverName = _str(x['receiverName']);
          final rFirst = _str(x['receiverFirstName']);
          final rLast = _str(x['receiverLastName']);
          final msgId = _int(x['messageId'] ?? x['MessageId'] ?? x['id']);
          sentJson.add({
            'id': msgId,
            'url': '',
            'topic': _str(x['topic']),
            'preview': _tryBase64Decode(x['content']),
            'hasAttachments': _bool(x['isAnyFileAttached']),
            'sendDate': _dateIso(x['sendDate']),
            'receivers': [
              {
                'id': -1,
                'url': '',
                'firstName': rFirst.isNotEmpty ? rFirst : receiverName,
                'lastName': rLast,
              }
            ],
          });
        }
      } catch (_) {}

      // Fallback to Gateway 2.0 Messages only if wiadomosci.librus.pl inbox failed
      if (primaryInboxError != null) {
        var recoveredViaGateway = false;
        try {
          final gwMsgs = await _apiGet('Messages');
          final list = _mapList(gwMsgs['Messages'] ?? gwMsgs['data']);
          for (final m in list) {
            final msgId = _int(m['Id'] ?? m['id'] ?? m['messageId']);
            final senderName = _str(m['SenderName'] ?? m['senderName']);
            final readIso = _dateIsoOrNull(m['ReadDate'] ?? m['readDate']);
            receivedJson.add({
              'id': msgId,
              'url': '',
              'topic': _str(m['Subject'] ?? m['topic']),
              'preview': _tryBase64Decode(m['Body'] ?? m['content']),
              'hasAttachments': _bool(m['IsAnyFileAttached'] ?? m['isAnyFileAttached']),
              'sendDate': _dateIso(m['SendDate'] ?? m['sendDate']),
              if (readIso != null) 'readDate': readIso,
              'sender': {
                'id': -1,
                'url': '',
                'firstName': senderName.isNotEmpty ? senderName : 'Unknown',
                'lastName': '',
              },
            });
          }
          recoveredViaGateway = true;
        } catch (_) {}

        if (!recoveredViaGateway) {
          return {
            'success': false,
            'message': '$primaryInboxError'.replaceFirst(RegExp(r'^Exception:\s*'), ''),
          };
        }
      }

      final messagesJson = <String, dynamic>{
        'received': receivedJson,
        'sent': sentJson,
        'receivers': receiversJson,
      };
      _registerData['messages'] = messagesJson;
      setRegisterDataJson({'messages': messagesJson});

      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> sendMessage(
    List<Map<String, dynamic>> receivers,
    String topic,
    String content,
  ) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.sendMessage(receivers, topic, content);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }

      final schoolReceivers = <Map<String, String>>[];
      for (final r in receivers) {
        schoolReceivers.add({'accountId': (r['userId'] ?? '').toString()});
      }

      final resp = await _messagesPost('messages', {
        'topic': base64.encode(utf8.encode(topic)),
        'content': base64.encode(utf8.encode(content)),
        'copyTo': null,
        'receivers': {'schoolReceivers': schoolReceivers},
        'storageId': null,
        'category': null,
      });

      final dataNode = resp['data'];
      final sentOk = dataNode is Map && dataNode['status'] == 'sent';
      return {'success': sentOk};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> fetchMessageContent(Map<String, dynamic> parent, bool byMe) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.fetchMessageContent(parent, byMe);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }

      final teachersList = _mapList((await _apiGet('Users'))['Users']);
      final userIdToAccount = await _loadMessageUserIds();
      for (final user in teachersList) {
        final aid = userIdToAccount[_int(user['Id']).toString()];
        if (aid != null) user['UserId'] = aid;
      }

      final parentId = _int(parent['id']);
      final endpoint = byMe ? 'outbox/messages/$parentId' : 'inbox/messages/$parentId';
      final rawResp = await _messagesGet(endpoint);

      dynamic rawData = rawResp['data'];
      if (rawData is List && rawData.isNotEmpty) {
        rawData = rawData.first;
      }
      final msgMap = rawData is Map ? rawData.cast<String, dynamic>() : <String, dynamic>{};

      final content = await _unwrapLinksAndMessageBody(msgMap['Message'] ?? msgMap['message']);
      final readIso = _dateIsoOrNull(msgMap['readDate']);

      Map<String, dynamic> resultMap;
      if (!byMe) {
        final senderIdInt = _intOrNull(msgMap['senderId']);
        Map<String, dynamic>? matchedSender;
        if (senderIdInt != null) {
          for (final u in teachersList) {
            if (_intOrNull(u['UserId']) == senderIdInt) {
              matchedSender = u;
              break;
            }
          }
        }
        final attachments = <Map<String, dynamic>>[];
        for (final att in _mapList(msgMap['attachments'])) {
          String? dlUrl;
          try {
            final attResp = await _messagesGet('attachments/${att['id']}/messages/$parentId');
            final attData = attResp['data'];
            if (attData is Map) {
              dlUrl = attData['downloadLink']?.toString();
              if (dlUrl != null && dlUrl.contains('GetFile')) {
                dlUrl = '$dlUrl/get';
              }
            }
          } catch (_) {}
          attachments.add({
            'name': att['filename']?.toString(),
            'location': dlUrl,
          });
        }

        resultMap = {
          'id': parentId,
          'url': _str(parent['url']),
          'topic': _str(msgMap['topic'], _str(parent['topic'], 'No topic')),
          'sendDate': _dateIso(msgMap['sendDate'] ?? parent['sendDate']),
          if (readIso != null) 'readDate': readIso,
          'content': content,
          'sender': matchedSender != null
              ? _teacherToJson(matchedSender)
              : {
                  'id': -1,
                  'url': '',
                  'firstName': _str(msgMap['senderFirstName'], 'Unknown'),
                  'lastName': _str(msgMap['senderLastName'], 'sender'),
                },
          'hasAttachments': attachments.isNotEmpty,
          'attachments': attachments,
        };
      } else {
        final outReceivers = <Map<String, dynamic>>[];
        for (final r in _mapList(msgMap['receivers'])) {
          final rId = _intOrNull(r['receiverId']);
          Map<String, dynamic>? matchedRec;
          if (rId != null) {
            for (final u in teachersList) {
              if (_intOrNull(u['UserId']) == rId) {
                matchedRec = u;
                break;
              }
            }
          }
          outReceivers.add(matchedRec != null
              ? _teacherToJson(matchedRec)
              : {
                  'id': -1,
                  'url': '',
                  'firstName': _str(r['firstName'], 'Unknown'),
                  'lastName': _str(r['lastName'], 'Receiver'),
                });
        }

        resultMap = {
          'id': parentId,
          'url': _str(parent['url']),
          'topic': _str(msgMap['topic'], _str(parent['topic'], 'No topic')),
          'sendDate': _dateIso(msgMap['sendDate'] ?? parent['sendDate']),
          if (readIso != null) 'readDate': readIso,
          'content': content,
          'hasAttachments': false,
          'receivers': outReceivers,
        };
      }

      return {'success': true, 'result': resultMap};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> moveMessageToTrash(Map<String, dynamic> parent, bool byMe) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.moveMessageToTrash(parent, byMe);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }
      await _messagesDelete('messages/${_int(parent['id'])}');
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> markEventAsViewed(Map<String, dynamic> parent) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.markEventAsViewed(parent);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }
      await _apiGet('HomeWorkAssignments/${_int(parent['id'])}');
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> markEventAsDone(Map<String, dynamic> parent) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.markEventAsDone(parent);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }
      await _apiPost('HomeWorkAssignments/MarkAsDone', {'homework': _int(parent['id'])});
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Future<Map<String, dynamic>> markAnnouncementAsViewed(Map<String, dynamic> parent) async {
    if (_sampleDriver != null) {
      return await _sampleDriver!.markAnnouncementAsViewed(parent);
    }

    try {
      if (!_loggedIn && _username.isNotEmpty && _password.isNotEmpty) {
        await _setupToken(reportUi: false);
      }
      await _apiPost('SchoolNotices/MarkAsRead/${_str(parent['url'])}', <String, dynamic>{});
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': '$e'.replaceFirst(RegExp(r'^Exception:\s*'), '')};
    }
  }

  @override
  Map<String, dynamic> getRegisterDataJson() => _registerData;
}

LibrusSynergiaExtension main(dynamic source) {
  return LibrusSynergiaExtension(source: source as OSource);
}
