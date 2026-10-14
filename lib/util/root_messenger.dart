import 'package:flutter/material.dart';

/// The app's own snackbar host, for messages that outlive the screen that sends them (such
/// as the recap of a sitting, shown as the reader closes).
final rootMessenger = GlobalKey<ScaffoldMessengerState>();
