import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/notification_action.dart';

/// The only caller of the notification-action function: sends one tapped
/// notification button ([NotificationAction]) to the server. Thin on purpose
/// (ARCHITECTURE rule 4); its decisions live in the domain.
final class NotificationActionApi {
  NotificationActionApi({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// POSTs the action as JSON to its ticket's url and maps the answer: 200 is
  /// done; 429 or any 5xx is retry; any other status is rejected. No answer in
  /// 15 seconds, or any network error, is retry. Never throws.
  Future<NotificationActionResult> send(NotificationAction action) async {
    try {
      final response = await _client
          .post(
            Uri.parse(action.ticket.url),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(action.toRequest()),
          )
          .timeout(const Duration(seconds: 15));
      final status = response.statusCode;
      if (status == 200) return NotificationActionResult.done;
      if (status == 429 || status >= 500) return NotificationActionResult.retry;
      return NotificationActionResult.rejected;
    } on Exception {
      return NotificationActionResult.retry;
    }
  }
}
