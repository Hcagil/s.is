// Apple's Sign in with Apple button from the sign_in_with_apple package, which
// sizes logo and title by Apple's rules. Lives in data/ because it is an SDK
// widget; screens receive it as a builder.

import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

Widget appleSignInButton(String text, VoidCallback onPressed) => SizedBox(
  key: const ValueKey('apple-sign-in'),
  width: double.infinity,
  child: SignInWithAppleButton(
    text: text,
    height: 48,
    borderRadius: BorderRadius.circular(14),
    onPressed: onPressed,
  ),
);
