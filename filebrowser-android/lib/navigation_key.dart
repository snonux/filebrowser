import 'package:flutter/material.dart';

/// Lets non-widget code show snack bars on whatever screen is visible.
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets code that outlives a screen show dialogs on the app's navigator.
final appNavigatorKey = GlobalKey<NavigatorState>();
