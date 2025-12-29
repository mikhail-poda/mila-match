import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  WordPair({required this.hebrew, required this.english});
}

class GameProgress {
  final int currentChunkIndex;

  GameProgress({required this.currentChunkIndex});

  Map<String, dynamic> toJson() => {'currentChunkIndex': currentChunkIndex};

  factory GameProgress.fromJson(Map<String, dynamic> json) => GameProgress(currentChunkIndex: json['currentChunkIndex'] ?? 0);
}

class MatchingGameScreen extends StatefulWidget {
  const MatchingGameScreen({super.key});

  @override
  State<MatchingGameScreen> createState() => _MatchingGameScreenState();
}

class _MatchingGameScreenState extends State<MatchingGameScreen> with SingleTickerProviderStateMixin {
  static const String version = '1.4';
  static const String prefsKey = 'hebrew_matching_progress';

  final GlobalKey<AnimatedListState> _matchedListKey = GlobalKey<AnimatedListState>();
  final GlobalKey<AnimatedListState> _hebrewListKey = GlobalKey<AnimatedListState>();
  final GlobalKey<AnimatedListState> _englishListKey = GlobalKey<AnimatedListState>();

  List<List<WordPair>> chunks = [];
  int currentChunkIndex = 0;
  List<WordPair> currentChunk = [];
  List<WordPair> hebrewList = [];
  List<WordPair> englishList = [];
  List<Map<String, WordPair>> matchedPairs = [];

  WordPair? selectedHebrew;
  WordPair? errorEnglish;
  WordPair? flashingHebrew;
  WordPair? flashingEnglish;

  bool isLoading = true;
  bool isProcessing = false;
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

      final prefs = await SharedPreferences.getInstance();
      final progressJson = prefs.getString(prefsKey);

      if (progressJson != null) {
        final progress = GameProgress.fromJson(json.decode(progressJson));
        currentChunkIndex = progress.currentChunkIndex.clamp(0, max(0, chunks.length - 1));
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

  Future<void> _saveProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final progress = GameProgress(currentChunkIndex: currentChunkIndex);
      await prefs.setString(prefsKey, json.encode(progress.toJson()));
    } catch (e) {}
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

    return rawChunks.expand((chunk) {
      chunk.shuffle();
      return chunk.length > 6 ? _splitIntoBalancedChunks(chunk, 6) : [chunk];
    }).toList();
  }

  static List<WordPair> _parseChunkLines(List<String> lines) {
    return lines
        .map((line) => line.split('\t'))
        .where((parts) => parts.length >= 2)
        .map((parts) => WordPair(hebrew: parts[0].trim(), english: parts[1].trim()))
        .where((pair) => pair.hebrew.isNotEmpty && pair.english.isNotEmpty)
        .toList();
  }

  List<List<WordPair>> _splitIntoBalancedChunks(List<WordPair> items, int maxSize) {
    int n = items.length;
    int numChunks = (n / maxSize).ceil();
    int baseSize = n ~/ numChunks;
    int remainder = n % numChunks;
    List<List<WordPair>> res = [];
    int currentIndex = 0;
    for (int i = 0; i < numChunks; i++) {
      int size = (i < remainder) ? baseSize + 1 : baseSize;
      res.add(items.sublist(currentIndex, currentIndex + size));
      currentIndex += size;
    }
    return res;
  }

  void _loadChunk() {
    if (chunks.isEmpty) return;
    setState(() {
      currentChunk = List.from(chunks[currentChunkIndex]);
      hebrewList = List.from(currentChunk);
      englishList = List.from(currentChunk);

      final nextIdx = (currentChunkIndex + 1) % chunks.length;
      final extraWord = chunks[nextIdx][Random().nextInt(chunks[nextIdx].length)];
      englishList.add(extraWord);

      hebrewList.shuffle();
      englishList.shuffle();
      matchedPairs = [];
      selectedHebrew = null;
      errorEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;
    });
    _saveProgress();
  }

  void _onHebrewTap(WordPair word) {
    if (isProcessing) return;
    setState(() {
      selectedHebrew = word;
      errorEnglish = null;
    });
  }

  void _onEnglishTap(WordPair word) async {
    if (selectedHebrew == null || isProcessing) return;

    if (selectedHebrew == word) {
      setState(() {
        isProcessing = true;
        flashingHebrew = selectedHebrew;
        flashingEnglish = word;
      });
      await Future.delayed(const Duration(milliseconds: 600));

      final hIdx = hebrewList.indexOf(selectedHebrew!);
      final eIdx = englishList.indexOf(word);
      final pair = {'hebrew': selectedHebrew!, 'english': word};

      matchedPairs.add(pair);
      _matchedListKey.currentState?.insertItem(matchedPairs.length - 1);

      hebrewList.removeAt(hIdx);
      _hebrewListKey.currentState?.removeItem(hIdx, (c, a) => _buildHebrewItem(pair['hebrew']!, a, true));

      englishList.removeAt(eIdx);
      _englishListKey.currentState?.removeItem(eIdx, (c, a) => _buildEnglishItem(pair['english']!, a, true));

      if (hebrewList.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (englishList.isNotEmpty) {
          final last = englishList.removeAt(0);
          _englishListKey.currentState?.removeItem(0, (c, a) => _buildEnglishItem(last, a, true));
        }
      }

      setState(() {
        selectedHebrew = null;
        flashingHebrew = null;
        flashingEnglish = null;
        isProcessing = false;
      });
    } else {
      setState(() {
        errorEnglish = word;
        isProcessing = true;
      });
      await _animationController?.forward(from: 0.0);
      setState(() {
        errorEnglish = null;
        isProcessing = false;
      });
    }
  }

  bool _isChunkComplete() => hebrewList.isEmpty && !isProcessing;

  Widget _buildMatchedPairItem(Map<String, WordPair> pair, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: animation,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 4.0),
            child: Row(
              children: [
                Expanded(
                    flex: 2,
                    child: Text(pair['hebrew']!.hebrew,
                        style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                        textScaler: const TextScaler.linear(2),
                        textAlign: TextAlign.right,
                        textDirection: TextDirection.rtl)),
                const SizedBox(width: 16),
                Expanded(
                    flex: 3, child: Text(pair['english']!.english, style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0), textScaler: const TextScaler.linear(2))),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
        ],
      ),
    );
  }

  Widget _buildHebrewItem(WordPair word, Animation<double> animation, [bool isRemoving = false]) {
    final isSelected = !isRemoving && selectedHebrew == word;
    final isFlashing = !isRemoving && flashingHebrew == word;

    return AnimatedBuilder(
      animation: _animationController!,
      builder: (context, child) {
        final offset = isFlashing ? sin(_animationController!.value * pi * 8) * 3 : 0.0;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: InkWell(
              onTap: isRemoving ? null : () => _onHebrewTap(word),
              child: Container(
                padding: const EdgeInsets.all(12.0),
                decoration: (isFlashing || isSelected) ? BoxDecoration(color: Colors.green.shade200, borderRadius: BorderRadius.circular(8)) : null,
                child: Text(word.hebrew,
                    style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                    textScaler: const TextScaler.linear(2),
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEnglishItem(WordPair word, Animation<double> animation, [bool isRemoving = false]) {
    final isError = !isRemoving && errorEnglish == word;
    final isFlashing = !isRemoving && flashingEnglish == word;

    return AnimatedBuilder(
      animation: _animationController!,
      builder: (context, child) {
        double offset = isError ? sin(_animationController!.value * pi * 4) * 5 : (isFlashing ? sin(_animationController!.value * pi * 8) * 3 : 0.0);
        return Transform.translate(
          offset: Offset(offset, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: InkWell(
              onTap: isRemoving ? null : () => _onEnglishTap(word),
              child: Container(
                padding: const EdgeInsets.all(12.0),
                decoration: isFlashing
                    ? BoxDecoration(color: Colors.green.shade200, borderRadius: BorderRadius.circular(8))
                    : (isError ? BoxDecoration(color: Colors.red.shade200, borderRadius: BorderRadius.circular(8)) : null),
                child: Text(word.english, style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0), textScaler: const TextScaler.linear(2)),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMatchingArea() {
    if (_isChunkComplete()) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: ListView(
            children: matchedPairs.map((p) => _buildMatchedPairItem(p, const AlwaysStoppedAnimation(1.0))).toList(),
          ),
        ),
      );
    }

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            AnimatedList(
              key: _matchedListKey,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              initialItemCount: matchedPairs.length,
              itemBuilder: (context, index, animation) => _buildMatchedPairItem(matchedPairs[index], animation),
            ),
            if (matchedPairs.isNotEmpty) const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hebrew column
                  Flexible(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 22.0),
                      child: AnimatedList(
                        key: _hebrewListKey,
                        initialItemCount: hebrewList.length,
                        itemBuilder: (c, i, a) => _buildHebrewItem(hebrewList[i], a),
                      ),
                    ),
                  ),

                  // THE VERTICAL SEPARATOR
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 30),
                    color: Colors.black12,
                  ),

                  // English column
                  Flexible(
                    flex: 3,
                    child: AnimatedList(
                      key: _englishListKey,
                      initialItemCount: englishList.length,
                      itemBuilder: (c, i, a) => _buildEnglishItem(englishList[i], a),
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
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Text(error!))
                : Column(
                    children: [
                      Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text('${currentChunkIndex + 1} / ${chunks.length}', style: const TextStyle(fontSize: 18, color: Colors.black45))),
                      _buildMatchingArea(),
                      if (_isChunkComplete())
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton(
                                  onPressed: _loadChunk,
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
                                  )),
                              const SizedBox(width: 16),
                              ElevatedButton(
                                  onPressed: () {
                                    currentChunkIndex = (currentChunkIndex + 1) % chunks.length;
                                    _loadChunk();
                                  },
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
                                  )),
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
