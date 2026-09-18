/// Release notes and changelog for a tagged release (docs/RELEASING.md).
///
/// Pure: the release workflow collects the inputs (`git log --first-parent`
/// and `gh pr list`) and `tool/release_notes.dart` does the file I/O.
///
/// `main` only moves by merge commit, so its first-parent history is one
/// commit per pull request. An entry is therefore a PR — titled by its
/// conventional-commit title, credited to the PR's author — and not the
/// "review round N" commits inside it.
library;

import 'dart:convert';

/// A commit on the first-parent history of the release range.
class Commit {
  const Commit({required this.sha, required this.subject});

  final String sha;
  final String subject;
}

/// A merged pull request, as `gh pr list --state merged --json ...` reports it.
class PullRequest {
  const PullRequest({
    required this.number,
    required this.title,
    required this.author,
    required this.isBot,
    required this.mergeSha,
    required this.mergedAt,
  });

  final int number;
  final String title;
  final String author;
  final bool isBot;
  final String mergeSha;
  final DateTime mergedAt;
}

/// Someone whose first merged pull request is part of this release.
class NewContributor {
  const NewContributor({required this.login, required this.firstPullRequest});

  final String login;
  final int firstPullRequest;
}

/// One line of the changelog.
class Entry {
  const Entry({
    required this.type,
    required this.description,
    this.scope,
    this.isBreaking = false,
    this.pullRequest,
    this.shortSha,
    this.author,
  });

  /// Reads a conventional-commit subject (`type(scope)!: description`).
  /// Anything else becomes an `other` entry with the subject untouched.
  factory Entry.parse(
    String subject, {
    int? pullRequest,
    String? shortSha,
    String? author,
  }) {
    final match = _conventional.firstMatch(subject.trim());
    final type = match?.group(1)?.toLowerCase();
    if (match == null || !_sectionTitles.containsKey(type)) {
      return Entry(
        type: _otherType,
        description: subject.trim(),
        pullRequest: pullRequest,
        shortSha: shortSha,
        author: author,
      );
    }
    return Entry(
      type: type!,
      scope: match.group(2),
      isBreaking: match.group(3) != null,
      description: match.group(4)!.trim(),
      pullRequest: pullRequest,
      shortSha: shortSha,
      author: author,
    );
  }

  final String type;
  final String? scope;
  final String description;
  final bool isBreaking;
  final int? pullRequest;
  final String? shortSha;
  final String? author;
}

const _otherType = 'other';
const _breakingTitle = '💥 Breaking Changes';
const _shortShaLength = 7;

/// Conventional-commit types, in the order their sections are printed.
/// `build` and `ci` share a section, as do `chore` and `style`.
const _sectionTitles = <String, String>{
  'feat': '✨ Features',
  'fix': '🐛 Bug Fixes',
  'perf': '⚡ Performance',
  'refactor': '♻️ Refactoring',
  'docs': '📚 Documentation',
  'test': '🧪 Tests',
  'build': '👷 Build & CI',
  'ci': '👷 Build & CI',
  'chore': '🧹 Chores',
  'style': '🧹 Chores',
  'revert': '⏪ Reverts',
  _otherType: '🔧 Other Changes',
};

final _conventional = RegExp(r'^([A-Za-z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$');
final _pullRequestMerge = RegExp(r'^Merge pull request #(\d+) ');
final _anyMerge = RegExp(r'^Merge ');

/// A PR title is text typed by whoever opened the PR, printed on the page
/// users trust for download links. It stays text: no link, no HTML, and no
/// `@mention` (a zero-width space after the `@` keeps GitHub from notifying).
String _plainText(String text) => text
    .replaceAllMapped(RegExp(r'[\[\]<>]'), (m) => '\\${m[0]}')
    .replaceAll('@', '@\u200B');

/// The changelog PR the release workflow opens is bookkeeping, not a change.
bool _isReleaseBookkeeping(Entry entry) =>
    entry.type == 'chore' && entry.scope == 'release';

/// Parses the output of `git log --first-parent --format=%H%x09%s`.
List<Commit> parseCommitLog(String log) => [
  for (final line in const LineSplitter().convert(log))
    if (line.contains('\t'))
      Commit(
        sha: line.substring(0, line.indexOf('\t')),
        subject: line.substring(line.indexOf('\t') + 1),
      ),
];

/// Parses `gh pr list --state merged
/// --json number,title,author,mergeCommit,mergedAt`.
List<PullRequest> parsePullRequests(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! List) {
    throw const FormatException('pull request listing is not a JSON array');
  }
  return [
    for (final item in decoded.whereType<Map<String, dynamic>>())
      if (item case {
        'number': final int number,
        'title': final String title,
        'mergedAt': final String mergedAt,
        'author': {'login': final String login},
        'mergeCommit': {'oid': final String oid},
      })
        PullRequest(
          number: number,
          title: title,
          author: login,
          isBot: (item['author'] as Map<String, dynamic>)['is_bot'] == true,
          mergeSha: oid,
          mergedAt: DateTime.parse(mergedAt),
        ),
  ];
}

class ReleaseNotes {
  const ReleaseNotes._({
    required this.tag,
    required this.previousTag,
    required this.repository,
    required this.date,
    required this.entries,
    required this.contributors,
    required this.newContributors,
  });

  /// [commits] is the first-parent history of `previousTag..tag` (of the
  /// whole history when [previousTag] is null). [pullRequests] is every
  /// merged PR of the repository: those outside the range tell a returning
  /// contributor from a new one.
  factory ReleaseNotes.build({
    required String tag,
    required String? previousTag,
    required String repository,
    required DateTime date,
    required List<Commit> commits,
    required List<PullRequest> pullRequests,
  }) {
    final byMergeSha = {for (final pr in pullRequests) pr.mergeSha: pr};
    final released = <PullRequest>[];
    final entries = <Entry>[];

    for (final commit in commits) {
      final pr = byMergeSha[commit.sha];
      if (pr != null) released.add(pr);
      final entry = _entryFor(commit, pr);
      if (entry != null && !_isReleaseBookkeeping(entry)) entries.add(entry);
    }

    final humans = released.where((pr) => !pr.isBot).toList();
    final contributors =
        {for (final pr in humans) pr.author}.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return ReleaseNotes._(
      tag: tag,
      previousTag: previousTag,
      repository: repository,
      date: date,
      entries: List.unmodifiable(entries),
      contributors: List.unmodifiable(contributors),
      newContributors:
          previousTag == null
              ? const []
              : List.unmodifiable(_newContributors(humans, pullRequests)),
    );
  }

  final String tag;
  final String? previousTag;
  final String repository;
  final DateTime date;
  final List<Entry> entries;
  final List<String> contributors;
  final List<NewContributor> newContributors;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  String get _repositoryUrl => 'https://github.com/$repository';

  static Entry? _entryFor(Commit commit, PullRequest? pr) {
    if (pr != null) {
      return Entry.parse(pr.title, pullRequest: pr.number, author: pr.author);
    }
    final merge = _pullRequestMerge.firstMatch(commit.subject);
    if (merge != null) {
      return Entry(
        type: _otherType,
        description: commit.subject,
        pullRequest: int.parse(merge.group(1)!),
      );
    }
    if (_anyMerge.hasMatch(commit.subject)) return null;
    final end =
        commit.sha.length < _shortShaLength
            ? commit.sha.length
            : _shortShaLength;
    return Entry.parse(commit.subject, shortSha: commit.sha.substring(0, end));
  }

  /// Authors of [released] with nothing merged before this release. A PR
  /// merged after it (the workflow re-run for an old tag) does not count.
  static List<NewContributor> _newContributors(
    List<PullRequest> released,
    List<PullRequest> all,
  ) {
    if (released.isEmpty) return const [];
    final releasedNumbers = {for (final pr in released) pr.number};
    final firstMerge = released
        .map((pr) => pr.mergedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final known = {
      for (final pr in all)
        if (!releasedNumbers.contains(pr.number) &&
            pr.mergedAt.isBefore(firstMerge))
          pr.author,
    };

    final firstByAuthor = <String, PullRequest>{};
    for (final pr in released.where((pr) => !known.contains(pr.author))) {
      final first = firstByAuthor[pr.author];
      if (first == null || pr.mergedAt.isBefore(first.mergedAt)) {
        firstByAuthor[pr.author] = pr;
      }
    }
    return [
      for (final pr in firstByAuthor.values)
        NewContributor(login: pr.author, firstPullRequest: pr.number),
    ]..sort((a, b) => a.firstPullRequest.compareTo(b.firstPullRequest));
  }

  /// The grouped list of changes — the part the release and the changelog
  /// share word for word.
  String renderChanges({String heading = '###'}) {
    if (entries.isEmpty) return '_No notable changes in this release._\n';

    final sections = <String, List<Entry>>{
      _breakingTitle: entries.where((e) => e.isBreaking).toList(),
      for (final title in _sectionTitles.values.toSet())
        title:
            entries
                .where((e) => !e.isBreaking && _sectionTitles[e.type] == title)
                .toList(),
    };

    final out = StringBuffer();
    for (final MapEntry(key: title, value: items) in sections.entries) {
      if (items.isEmpty) continue;
      out.writeln('$heading $title\n');
      items.map(_renderEntry).forEach(out.writeln);
      out.writeln();
    }
    return out.toString();
  }

  String _renderEntry(Entry entry) {
    final scope =
        entry.scope == null ? '' : '**${_plainText(entry.scope!)}:** ';
    final reference =
        entry.pullRequest != null
            ? ' ([#${entry.pullRequest}]($_repositoryUrl/pull/${entry.pullRequest}))'
            : entry.shortSha != null
            ? ' ([`${entry.shortSha}`]($_repositoryUrl/commit/${entry.shortSha}))'
            : '';
    final author = entry.author == null ? '' : ' by @${entry.author}';
    return '- $scope${_plainText(entry.description)}$reference$author';
  }

  /// The section this release adds to `CHANGELOG.md`.
  String renderChangelogSection() {
    final day = date.toUtc().toIso8601String().substring(0, 10);
    return '## [$version] - $day\n\n${renderChanges()}';
  }

  /// The description of the GitHub release.
  String renderReleaseBody() {
    final out =
        StringBuffer()
          ..writeln('# ⚡ Mostro $tag\n')
          ..writeln(
            'Non-custodial, peer-to-peer Bitcoin trading over Lightning and '
            'Nostr.\n',
          )
          ..writeln(_androidDownloads())
          ..writeln("## 📋 What's changed\n")
          ..write(renderChanges());

    if (contributors.isNotEmpty) {
      out
        ..writeln('## 👥 Contributors\n')
        ..writeln('Thanks to everyone who made this release possible:\n')
        ..writeln(contributors.map((login) => '@$login').join(' · '))
        ..writeln();
    }
    if (newContributors.isNotEmpty) {
      out.writeln('## 🌱 New Contributors\n');
      for (final contributor in newContributors) {
        final number = contributor.firstPullRequest;
        out.writeln(
          '- @${contributor.login} made their first contribution in '
          '[#$number]($_repositoryUrl/pull/$number)',
        );
      }
      out.writeln();
    }

    out.writeln('---\n');
    if (previousTag != null) {
      out.writeln(
        '**Full diff**: $_repositoryUrl/compare/$previousTag...$tag · ',
      );
    }
    out.writeln(
      '**History**: [CHANGELOG.md]($_repositoryUrl/blob/main/CHANGELOG.md)',
    );
    return out.toString();
  }

  /// File names must match what release.yml uploads; a test holds them equal.
  String _androidDownloads() => '''
## 📥 Downloads

### 🤖 Android

| File | Architecture | For |
| --- | --- | --- |
| [`mostro-$tag-arm64-v8a.apk`]($_repositoryUrl/releases/download/$tag/mostro-$tag-arm64-v8a.apk) | **v8** — ARMv8-A, 64-bit (AArch64) | **Modern phones.** Pick this one if unsure. |
| [`mostro-$tag-armeabi-v7a.apk`]($_repositoryUrl/releases/download/$tag/mostro-$tag-armeabi-v7a.apk) | **v7** — ARMv7-A, 32-bit | **Old or entry-level phones** that run a 32-bit Android. |

Both need **Android 7.0 (API 24) or later** and are the same app: an APK holds
native machine code (the Flutter engine and Mostro's Rust core, which does all
the cryptography), and one file per CPU instruction set keeps each download to
a fraction of the size of a universal APK.

<details>
<summary><b>Which one is mine?</b></summary>

- **`arm64-v8a` (v8)** targets the 64-bit ARMv8-A instruction set. Practically
  every phone released since 2016–2017 runs a 64-bit Android, Google Play has
  required 64-bit builds since August 2019, and recent devices — the Pixel 7
  and later, and any phone built on 2023-or-newer Arm cores — are
  **64-bit only**: they cannot run the v7 APK at all. 64-bit code is also
  noticeably faster at the elliptic-curve and encryption work the app does.
- **`armeabi-v7a` (v7)** targets 32-bit ARMv7-A with hardware floating point.
  It is for phones with a 32-bit CPU (Cortex-A7/A9/A15 class, roughly 2015
  and earlier) **and** for phones whose 64-bit-capable CPU ships with a
  32-bit Android — common in budget and Android Go models with 2 GB of RAM
  or less.
- **To be sure:** try v8 first. If Android answers *"App not installed"* or
  *"package is not compatible with your phone"*, install v7. With a computer,
  `adb shell getprop ro.product.cpu.abilist` prints the supported ABIs —
  if `arm64-v8a` is in the list, use v8.
- x86 devices (emulators, some Chromebooks) are not covered by these builds.

</details>

Verify a download with `sha256sum -c SHA256SUMS.txt --ignore-missing`. Every
release is signed with the same key, so it installs over the previous version
and keeps your data.
''';
}

const _changelogHeader = '''
# Changelog

All notable changes to Mostro are documented here, newest first. This file is
written by the release workflow (docs/RELEASING.md) — do not edit it by hand.
Versions follow [Semantic Versioning](https://semver.org/).
''';

final _sectionStart = RegExp(r'^## \[', multiLine: true);

/// Returns [existing] with [section] as the entry for [version]: placed above
/// the older versions, or replacing the section a previous run wrote.
String upsertChangelog(String? existing, String version, String section) {
  final text =
      (existing == null || existing.trim().isEmpty)
          ? _changelogHeader.trimLeft()
          : existing;
  final firstSection = _sectionStart.firstMatch(text)?.start ?? text.length;
  final header = text.substring(0, firstSection).trimRight();
  final others = text
      .substring(firstSection)
      .split(RegExp(r'(?=^## \[)', multiLine: true))
      .where((s) => s.trim().isNotEmpty && !s.startsWith('## [$version]'))
      .map((s) => s.trimRight());

  return '${[header, section.trimRight(), ...others].join('\n\n')}\n';
}
