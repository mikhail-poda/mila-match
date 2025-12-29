import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hebrew Matching Game',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MatchingGameScreen(),
    );
  }
}

class WordPair {
  final String hebrew;
  final String english;

  WordPair({
    required this.hebrew,
    required this.english,
  });

  Map<String, dynamic> toJson() => {
        'hebrew': hebrew,
        'english': english,
      };

  factory WordPair.fromJson(Map<String, dynamic> json) => WordPair(
        hebrew: json['hebrew'],
        english: json['english'],
      );
}

class GameProgress {
  final int currentChunkIndex;

  GameProgress({
    required this.currentChunkIndex,
  });

  Map<String, dynamic> toJson() => {
        'currentChunkIndex': currentChunkIndex,
      };

  factory GameProgress.fromJson(Map<String, dynamic> json) =>
      GameProgress(currentChunkIndex: json['currentChunkIndex'] ?? 0);
}

class MatchingGameScreen extends StatefulWidget {
  const MatchingGameScreen({super.key});

  @override
  State<MatchingGameScreen> createState() => _MatchingGameScreenState();
}

class _MatchingGameScreenState extends State<MatchingGameScreen>
    with SingleTickerProviderStateMixin {
  static const String version = '1.0';
  static const String prefsKey = 'hebrew_matching_progress';

  List<List<WordPair>> chunks = [];
  int currentChunkIndex = 0;

  List<WordPair> currentChunk = [];
  List<WordPair> hebrewList = [];
  List<WordPair> englishList = [];

  // Track matched pairs in order (stack)
  List<Map<String, WordPair>> matchedPairs = [];

  WordPair? selectedHebrew;
  WordPair? errorEnglish;
  WordPair? flashingHebrew;
  WordPair? flashingEnglish;

  bool isLoading = true;
  String? error;
  AnimationController? _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _loadVocabulary();
  }

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }

  Future<void> _loadVocabulary() async {
    try {
      setState(() {
        isLoading = true;
        error = null;
      });

      final content = await rootBundle.loadString('assets/vocabulary.tsv');
      chunks = _parseChunks(content);

      // Load progress
      final prefs = await SharedPreferences.getInstance();
      final progressJson = prefs.getString(prefsKey);

      if (progressJson != null) {
        final progress = GameProgress.fromJson(json.decode(progressJson));
        currentChunkIndex =
            progress.currentChunkIndex.clamp(0, chunks.length - 1);
      }

      _loadChunk();

      setState(() {
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        error = e.toString();
      });
    }
  }

  List<List<WordPair>> _splitIntoBalancedChunks(
      List<WordPair> items, int maxSize) {
    int n = items.length;
    if (maxSize <= 0) {
      throw ArgumentError('Max chunk size must be greater than 0');
    }
    if (n == 0) return [];

    // Calculate the minimum number of chunks required
    int numChunks = (n / maxSize).ceil();

    // Determine base size and how many chunks get an extra item
    int baseSize = n ~/ numChunks;
    int remainder = n % numChunks;

    List<List<WordPair>> chunks = [];
    int currentIndex = 0;

    for (int i = 0; i < numChunks; i++) {
      // The first 'remainder' chunks get (baseSize + 1) items
      int currentChunkSize = (i < remainder) ? baseSize + 1 : baseSize;

      chunks.add(items.sublist(currentIndex, currentIndex + currentChunkSize));
      currentIndex += currentChunkSize;
    }

    return chunks;
  }

  List<List<WordPair>> _parseChunks(String content) {
    final rawChunks = content
        .split('\n')
        .map((line) => line.trim())
        .splitBefore((line) => line.isEmpty)
        .map((chunk) => chunk.where((line) => line.isNotEmpty).toList())
        .where((chunk) => chunk.isNotEmpty)
        .map(_parseChunkLines)
        .toList();

    // Process chunks: shuffle and split if needed
    final processedChunks = rawChunks.expand((chunk) {
      chunk.shuffle();
      return chunk.length > 6
          ? _splitIntoBalancedChunks(chunk, 6)
          : [chunk];
    }).toList();

    return processedChunks;
  }

  // Parse a chunk of TSV lines into WordPairs
  static List<WordPair> _parseChunkLines(List<String> lines) {
    return lines
        .map((line) => line.split('\t'))
        .where((parts) => parts.length >= 2)
        .map((parts) => WordPair(hebrew: parts[0].trim(), english: parts[1].trim()))
        .where((pair) => pair.hebrew.isNotEmpty && pair.english.isNotEmpty)
        .toList();
  }

  void _loadChunk() {
    if (chunks.isEmpty) return;

    currentChunk = List.from(chunks[currentChunkIndex]);

    // Create Hebrew and English lists with randomized order
    hebrewList = List.from(currentChunk);
    englishList = List.from(currentChunk);

    // Add one extra English word from next chunk (or previous if on last chunk)
    final extraChunkIndex = currentChunkIndex < chunks.length - 1 ? currentChunkIndex + 1 : 0;
    final nextChunk = chunks[extraChunkIndex];
    final extraWord = nextChunk[Random().nextInt(nextChunk.length)];
    englishList.add(extraWord);

    hebrewList.shuffle();
    englishList.shuffle();

    matchedPairs = [];
    selectedHebrew = null;
    errorEnglish = null;
    flashingHebrew = null;
    flashingEnglish = null;
  }

  Future<void> _saveProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final progress = GameProgress(currentChunkIndex: currentChunkIndex);
      await prefs.setString(prefsKey, json.encode(progress.toJson()));
    } catch (e) {
      _showError('Error saving progress: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onHebrewTap(WordPair word) {
    if (_isMatched(word)) return;

    setState(() {
      selectedHebrew = word;
      errorEnglish = null;
    });
  }

  bool _isMatched(WordPair word) {
    return matchedPairs
        .any((pair) => pair['hebrew'] == word || pair['english'] == word);
  }

  void _onEnglishTap(WordPair word) async {
    if (_isMatched(word) || selectedHebrew == null) return;

    // Check if they're the same WordPair (correct match)
    final isCorrect = selectedHebrew == word;

    if (isCorrect) {
      // Flash green with shake animation for 2 seconds
      setState(() {
        flashingHebrew = selectedHebrew;
        flashingEnglish = word;
      });

      _animationController?.duration = const Duration(milliseconds: 2000);
      _animationController?.forward(from: 0.0);
      await Future.delayed(const Duration(seconds: 2));

      setState(() {
        matchedPairs.add({
          'hebrew': selectedHebrew!,
          'english': word,
        });
        selectedHebrew = null;
        flashingHebrew = null;
        flashingEnglish = null;
        errorEnglish = null;
      });
    } else {
      setState(() {
        errorEnglish = word;
      });

      _animationController?.duration = const Duration(milliseconds: 500);
      _animationController?.forward(from: 0.0).then((_) {
        setState(() {
          errorEnglish = null;
        });
      });
    }
  }

  bool _isChunkComplete() {
    return hebrewList.every((word) => _isMatched(word));
  }

  void _nextChunk() {
    if (currentChunkIndex < chunks.length - 1) {
      setState(() {
        currentChunkIndex++;
        _loadChunk();
      });
      _saveProgress();
    } else {
      // All chunks completed - restart from beginning
      setState(() {
        currentChunkIndex = 0;
        _loadChunk();
      });
      _saveProgress();
    }
  }

  void _repeatChunk() {
    setState(() {
      _loadChunk();
    });
  }

  Widget _buildLoadingScreen() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading vocabulary...'),
        ],
      ),
    );
  }

  Widget _buildErrorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Error Loading Vocabulary',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(error ?? 'Unknown error'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadVocabulary,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: Text(
          '${currentChunkIndex + 1} / ${chunks.length}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.normal, color: Colors.black45),
        ),
      ),
    );
  }

  Widget _buildMatchingArea() {
    // Get unmatched words
    final unmatchedHebrew =
        hebrewList.where((word) => !_isMatched(word)).toList();
    final unmatchedEnglish = _isChunkComplete()
        ? <WordPair>[]
        : englishList.where((word) => !_isMatched(word)).toList();

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            // Matched pairs section - in stack order (last matched at bottom)
            if (matchedPairs.isNotEmpty) ...[
              ...matchedPairs.expand((pair) {
                final hebrewWord = pair['hebrew']!.hebrew;
                final englishWord = pair['english']!.english;

                return [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 8.0, horizontal: 4.0),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(
                            hebrewWord,
                            textScaler: const TextScaler.linear(2),
                            style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                            textAlign: TextAlign.right,
                            textDirection: TextDirection.rtl,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 3,
                          child: Text(
                            englishWord,
                            textScaler: const TextScaler.linear(2),
                            style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                ];
              }).toList(),
              const SizedBox(height: 16),
            ],

            // Unmatched pairs section
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hebrew column - narrower and offset by half row
                  Flexible(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 22.0),
                      // Half-row offset
                      child: ListView.builder(
                        itemCount: unmatchedHebrew.length,
                        itemBuilder: (context, i) {
                          final word = unmatchedHebrew[i];
                          final isSelected = selectedHebrew == word;
                          final isFlashing = flashingHebrew == word;

                          return AnimatedBuilder(
                            animation: _animationController!,
                            builder: (context, child) {
                              final successValue = isFlashing
                                  ? _animationController!.value
                                  : 0.0;
                              final shakeOffset =
                                  sin(successValue * pi * 8) * 3;

                              return Transform.translate(
                                offset: Offset(shakeOffset, 0),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2.0),
                                  child: InkWell(
                                    onTap: () => _onHebrewTap(word),
                                    child: Container(
                                      padding: const EdgeInsets.all(12.0),
                                      decoration: isFlashing
                                          ? BoxDecoration(
                                              color: Colors.green.shade200,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            )
                                          : isSelected
                                              ? BoxDecoration(
                                                  color: Colors.green.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                )
                                              : null,
                                      child: Text(
                                        word.hebrew,
                                        textScaler: const TextScaler.linear(2),
                                        style: TextStyle(
                                            fontWeight: (isSelected || isFlashing) ? FontWeight.normal : FontWeight.normal,
                                            height: 1.0
                                        ),
                                        textAlign: TextAlign.right,
                                        textDirection: TextDirection.rtl,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),

                  const SizedBox(width: 16),

                  // English column - wider
                  Flexible(
                    flex: 3,
                    child: ListView.builder(
                      itemCount: unmatchedEnglish.length,
                      itemBuilder: (context, i) {
                        final word = unmatchedEnglish[i];
                        final isError = errorEnglish == word;
                        final isFlashing = flashingEnglish == word;

                        return AnimatedBuilder(
                          animation: _animationController!,
                          builder: (context, child) {
                            double shakeOffset = 0;
                            if (isError) {
                              final errorValue = _animationController!.value;
                              shakeOffset = sin(errorValue * pi * 4) * 5;
                            } else if (isFlashing) {
                              final successValue = _animationController!.value;
                              shakeOffset = sin(successValue * pi * 8) * 3;
                            }

                            return Transform.translate(
                              offset: Offset(shakeOffset, 0),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2.0),
                                child: InkWell(
                                  onTap: () => _onEnglishTap(word),
                                  child: Container(
                                    padding: const EdgeInsets.all(12.0),
                                    decoration: isFlashing
                                        ? BoxDecoration(
                                            color: Colors.green.shade200,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          )
                                        : isError
                                            ? BoxDecoration(
                                                color: Colors.red.shade200,
                                                borderRadius: BorderRadius.circular(8),
                                              )
                                            : null,
                                    child: Text(
                                      word.english,
                                      textScaler: const TextScaler.linear(2),
                                      style: const TextStyle(height: 1.0),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: isLoading
            ? _buildLoadingScreen()
            : error != null
                ? _buildErrorScreen()
                : Column(
                    children: [
                      _buildHeader(),
                      _buildMatchingArea(),
                      if (_isChunkComplete())
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton(
                                onPressed: _repeatChunk,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                    horizontal: 32,
                                  ),
                                ),
                                child: const Text(
                                  'Repeat List',
                                  style: TextStyle(fontSize: 20),
                                ),
                              ),
                              const SizedBox(width: 16),
                              ElevatedButton(
                                onPressed: _nextChunk,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                    horizontal: 32,
                                  ),
                                ),
                                child: const Text(
                                  'Next List',
                                  style: TextStyle(fontSize: 20),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          'Version: $version',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
