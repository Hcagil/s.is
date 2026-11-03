/// Enum of bot command kinds.
enum BotCommandKind {
  /// Add iOS tester.
  addIos,

  /// Add Android tester.
  addAndroid,

  /// Remove tester.
  removeTester,

  /// List testers.
  listTesters,

  /// Turn podium on.
  podiumOn,

  /// Turn podium off.
  podiumOff,

  /// Podium command.
  podium,
}

/// A bot command definition.
class BotCommand {
  /// Creates a [BotCommand] with the given [name] and [kind].
  const BotCommand(this.name, this.kind, {this.takesEmail = false});

  /// The command name (e.g., '/addiostester').
  final String name;

  /// The kind of command.
  final BotCommandKind kind;

  /// Whether this command takes an email argument.
  final bool takesEmail;
}

/// Admin commands.
const adminCommands = <BotCommand>[
  BotCommand('/addiostester', BotCommandKind.addIos, takesEmail: true),
  BotCommand('/addandroidtester', BotCommandKind.addAndroid, takesEmail: true),
  BotCommand('/removetester', BotCommandKind.removeTester, takesEmail: true),
  BotCommand('/listtesters', BotCommandKind.listTesters),
  BotCommand('/podiumon', BotCommandKind.podiumOn),
  BotCommand('/podiumoff', BotCommandKind.podiumOff),
];

/// Bacanaks commands.
const bacanaksCommands = <BotCommand>[
  BotCommand('/podium', BotCommandKind.podium),
];

/// Returns commands from [all] whose name starts with [typed]; empty unless
/// [typed] starts with '/' and has no space or newline yet.
List<BotCommand> matchCommands(List<BotCommand> all, String typed) {
  final t = typed.trimLeft();
  if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) {
    return const [];
  }
  return all.where((c) => c.name.startsWith(t.toLowerCase())).toList();
}
