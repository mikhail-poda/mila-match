import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

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
  static const String version = '1.8';
  static const String prefsKey = 'hebrew_matching_progress';

  GlobalKey<AnimatedListState> _matchedListKey = GlobalKey<AnimatedListState>();
  GlobalKey<AnimatedListState> _hebrewListKey = GlobalKey<AnimatedListState>();
  GlobalKey<AnimatedListState> _englishListKey = GlobalKey<AnimatedListState>();

  List<List<WordPair>> chunks = [];
  int currentChunkIndex = 0;
  List<WordPair> currentChunk = [];
  List<WordPair> hebrewList = [];
  List<String> englishList = [];
  List<WordPair> matchedPairs = [];

  WordPair? selectedHebrew;
  String? errorEnglish;
  WordPair? flashingHebrew;
  String? flashingEnglish;

  bool isLoading = true;
  bool isProcessing = false;
  String? error;
  AnimationController? _animationController;

  // Audio dictation mode state
  bool isAudioMode = false;

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

  void _playHebrewWord(String hebrewWord) {
    try {
      final speechSynthesis = web.window.speechSynthesis;
      final utterance = web.SpeechSynthesisUtterance(hebrewWord);

      utterance.lang = 'he-IL';
      utterance.rate = 0.8;
      utterance.pitch = 1.0;

      speechSynthesis.speak(utterance);
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  void _toggleAudioMode() {
    if (isProcessing) return;

    setState(() {
      isAudioMode = !isAudioMode;
      if (isAudioMode) {
        selectedHebrew = null;
        _dictateNextWord();
      } else {
        selectedHebrew = null;
        web.window.speechSynthesis.cancel();
      }
    });
  }

  void _dictateNextWord() {
    if (hebrewList.isEmpty) {
      setState(() {
        isAudioMode = false;
      });
      return;
    }

    final randomIndex = Random().nextInt(hebrewList.length);
    final word = hebrewList[randomIndex];

    setState(() {
      selectedHebrew = word;
    });

    _playHebrewWord(word.hebrew);
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
      return chunk.length > 7 ? _splitIntoBalancedChunks(chunk, 6) : [chunk];
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
      englishList = currentChunk.map((x) => x.english).toList();

      // Determine if current chunk contains verbs
      final isVerbChunk = currentChunk.first.english.startsWith('to ');

      // Find extraWord from same category (verb or not-verb)
      WordPair? extraWord;
      for (int i = 1; i < chunks.length; i++) {
        final idx = (currentChunkIndex + i) % chunks.length;
        final candidate = chunks[idx][Random().nextInt(chunks[idx].length)];
        final isVerb = candidate.english.startsWith('to ');
        if (isVerb == isVerbChunk) {
          extraWord = candidate;
          break;
        }
      }
      if (extraWord != null) {
        englishList.add(extraWord.english);
      }

      hebrewList.shuffle();
      englishList.shuffle();
      matchedPairs = [];
      selectedHebrew = null;
      errorEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;

      // Reset audio mode state
      isAudioMode = false;
    });
    _saveProgress();
  }

  void _onHebrewTap(WordPair word) {
    if (isProcessing || isAudioMode) return; // Disable Hebrew tapping in audio mode
    setState(() {
      selectedHebrew = word;
      errorEnglish = null;
    });
  }

  void _onEnglishTap(String englishWord) async {
    if (selectedHebrew == null || isProcessing) return;

    if (selectedHebrew!.english == englishWord) {
      setState(() {
        isProcessing = true;
        flashingHebrew = selectedHebrew;
        flashingEnglish = englishWord;
      });
      await Future.delayed(const Duration(milliseconds: 600));

      final hIdx = hebrewList.indexOf(selectedHebrew!);
      final eIdx = englishList.indexOf(englishWord);
      final matchedHebrew = selectedHebrew!; // Capture before using in closures

      matchedPairs.add(matchedHebrew);
      _matchedListKey.currentState?.insertItem(matchedPairs.length - 1);

      hebrewList.removeAt(hIdx);
      _hebrewListKey.currentState?.removeItem(hIdx, (c, a) => _buildHebrewItem(matchedHebrew, a, true));

      englishList.removeAt(eIdx);
      _englishListKey.currentState?.removeItem(eIdx, (c, a) => _buildEnglishItem(englishWord, a, true));

      if (hebrewList.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (englishList.isNotEmpty) {
          final last = englishList.removeAt(0);
          _englishListKey.currentState?.removeItem(0, (c, a) => _buildEnglishItem(last, a, true));
          await Future.delayed(const Duration(milliseconds: 350)); // wait for animation
        }
        _resetAnimatedListKeys();

        // Turn off audio mode when chunk is complete
        setState(() {
          isAudioMode = false;
        });
      }

      setState(() {
        selectedHebrew = null;
        flashingHebrew = null;
        flashingEnglish = null;
        isProcessing = false;
      });

      // In audio mode, dictate the next word after a delay
      if (isAudioMode && hebrewList.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 1));
        _dictateNextWord();
      }
    } else {
      setState(() {
        errorEnglish = englishWord;
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

  void _openExternalLink(String link) {
    final jsUrl = Uri.encodeFull(link);
    web.window.open(jsUrl, '_blank');
  }

  Widget _buildMatchedPairItem(WordPair pair, Animation<double> animation) {
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
                  child: InkWell(
                    onTap: () => _openExternalLink('https://www.pealim.com/search/?q=${pair.hebrew}'),
                    child: Text(
                      pair.hebrew,
                      style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                      textScaler: const TextScaler.linear(1.75),
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: InkWell(
                    onTap: () => _openExternalLink('https://context.reverso.net/translation/hebrew-english/${pair.hebrew}'),
                    child: Text(
                      pair.english,
                      style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0),
                      textScaler: const TextScaler.linear(1.75),
                    ),
                  ),
                ),
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
                    textScaler: const TextScaler.linear(1.75),
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEnglishItem(String word, Animation<double> animation, [bool isRemoving = false]) {
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
                child: Text(word, style: const TextStyle(fontWeight: FontWeight.normal, height: 1.0), textScaler: const TextScaler.linear(1.75)),
              ),
            ),
          ),
        );
      },
    );
  }

  void _resetAnimatedListKeys() {
    _matchedListKey = GlobalKey<AnimatedListState>();
    _hebrewListKey = GlobalKey<AnimatedListState>();
    _englishListKey = GlobalKey<AnimatedListState>();
  }

  void _previousChunk() {
    _resetAnimatedListKeys();
    currentChunkIndex = (currentChunkIndex - 1 + chunks.length) % chunks.length;
    _loadChunk();
  }

  void _nextChunk() {
    _resetAnimatedListKeys();
    currentChunkIndex = (currentChunkIndex + 1) % chunks.length;
    _loadChunk();
  }

  void _orderChunk() {
    if (chunks.isEmpty) return;

    _resetAnimatedListKeys();

    setState(() {
      matchedPairs = List.from(currentChunk);

      hebrewList = [];
      englishList = [];

      selectedHebrew = null;
      errorEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;

      // Reset audio mode state
      isAudioMode = false;
    });
  }

  Widget _buildMatchingArea() {
    final key = ValueKey('chunk_area_$currentChunkIndex');

    if (_isChunkComplete()) {
      return Expanded(
        key: key,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: ListView(
            children: matchedPairs.map((p) => _buildMatchedPairItem(p, const AlwaysStoppedAnimation(1.0))).toList(),
          ),
        ),
      );
    }

    return Expanded(
      key: key,
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
                  // Hebrew list - hidden in audio mode
                  Flexible(
                    flex: 2,
                    child: Visibility(
                      visible: !isAudioMode,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 22.0),
                        child: AnimatedList(
                          key: _hebrewListKey,
                          initialItemCount: hebrewList.length,
                          itemBuilder: (c, i, a) => _buildHebrewItem(hebrewList[i], a),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 30),
                    color: Colors.black12,
                  ),
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
                        child: Text('${currentChunkIndex + 1} / ${chunks.length}', style: const TextStyle(fontSize: 18, color: Colors.black45)),
                      ),
                      _buildMatchingArea(),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Previous - blue
                            ElevatedButton(
                              onPressed: _previousChunk,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(16),
                                shape: const CircleBorder(),
                              ),
                              child: const Icon(Icons.chevron_left, size: 28),
                            ),
                            const SizedBox(width: 12),
                            // Play/Pause - gray (only if chunk not complete)
                            ElevatedButton(
                              onPressed: _isChunkComplete() ? null : _toggleAudioMode,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: Colors.grey.shade300,
                                disabledForegroundColor: Colors.white54,
                                padding: const EdgeInsets.all(16),
                                shape: const CircleBorder(),
                              ),
                              child: Icon(isAudioMode ? Icons.pause : Icons.play_arrow, size: 28),
                            ),
                            const SizedBox(width: 12),
                            // Random/Ordered - orange
                            ElevatedButton(
                              onPressed: _isChunkComplete() ? _loadChunk : _orderChunk,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(16),
                                shape: const CircleBorder(),
                              ),
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: Center(
                                  child: Text(
                                    _isChunkComplete() ? '⟳' : '≡',
                                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, height: 1.0),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Next - green
                            ElevatedButton(
                              onPressed: _nextChunk,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(16),
                                shape: const CircleBorder(),
                              ),
                              child: const Icon(Icons.chevron_right, size: 28),
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
