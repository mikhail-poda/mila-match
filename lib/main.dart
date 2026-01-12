import 'dart:convert';
import 'dart:math';

import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

enum GameMode { normal, audio, typing }

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
  static const String version = '2.1';
  static const String prefsKey = 'hebrew_matching_progress';

  GlobalKey<AnimatedListState> _matchedListKey = GlobalKey<AnimatedListState>();
  GlobalKey<AnimatedListState> _hebrewListKey = GlobalKey<AnimatedListState>();
  GlobalKey<AnimatedListState> _englishListKey = GlobalKey<AnimatedListState>();

  List<List<WordPair>> chunks = [];
  int currentChunkIndex = 0;
  List<WordPair> currentChunk = [];
  List<String> hebrewList = [];
  List<String> englishList = [];
  List<WordPair> matchedPairs = [];

  // Selection state - only one can be selected at a time
  String? selectedHebrew;
  String? selectedEnglish;

  // Error state for both sides
  String? errorHebrew;
  String? errorEnglish;

  // Flashing state for match animation
  String? flashingHebrew;
  String? flashingEnglish;

  bool isLoading = true;
  bool isProcessing = false;
  String? error;
  AnimationController? _animationController;

  // Game mode state
  GameMode gameMode = GameMode.normal;
  bool _isModeSwitchExpanded = false;

  // Typing mode
  final TextEditingController _hebrewInputController = TextEditingController();
  final FocusNode _hebrewInputFocusNode = FocusNode();

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
    _hebrewInputController.dispose();
    _hebrewInputFocusNode.dispose();
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

  // Strip niqqud (Hebrew vowel marks) for comparison
  String _stripNiqqud(String text) {
    // Hebrew niqqud range: U+0591 to U+05C7
    return text.replaceAll(RegExp(r'[\u0591-\u05C7]'), '');
  }

  void _submitTypedHebrew() async {
    if (isProcessing || selectedEnglish == null) return;

    final typedHebrew = _hebrewInputController.text.trim();
    if (typedHebrew.isEmpty) return;

    // Find if there's a matching pair
    final strippedTyped = _stripNiqqud(typedHebrew);

    WordPair? matchedPair;
    for (final pair in currentChunk) {
      if (pair.english == selectedEnglish && _stripNiqqud(pair.hebrew) == strippedTyped) {
        matchedPair = pair;
        break;
      }
    }

    if (matchedPair != null) {
      // Show green flash on input field
      setState(() {
        flashingHebrew = '_typing_success';
        isProcessing = true;
      });
      await Future.delayed(const Duration(milliseconds: 800));

      setState(() {
        flashingHebrew = null;
      });
      _hebrewInputController.clear();

      await _handleCorrectMatch(matchedPair);
    } else {
      // Wrong - show error animation on input (keep text for editing)
      setState(() {
        errorHebrew = '_typing_error';
        isProcessing = true;
      });
      await _animationController?.forward(from: 0.0);
      setState(() {
        errorHebrew = null;
        isProcessing = false;
      });
      _hebrewInputFocusNode.requestFocus();
    }
  }

  void _onModeChanged(GameMode mode) {
    if (isProcessing) return;

    final previousMode = gameMode;

    setState(() {
      gameMode = mode;
      selectedHebrew = null;
      selectedEnglish = null;
      _isModeSwitchExpanded = false; // Collapse after selection
    });

    // Handle mode transitions
    if (previousMode == GameMode.audio) {
      web.window.speechSynthesis.cancel();
    }

    if (mode == GameMode.audio) {
      _dictateNextWord();
    } else if (mode == GameMode.typing) {
      _hebrewInputController.clear();
    }
  }

  void _dictateNextWord() {
    if (hebrewList.isEmpty) {
      return;
    }

    final randomIndex = Random().nextInt(hebrewList.length);
    final word = hebrewList[randomIndex];

    setState(() {
      selectedHebrew = word;
      selectedEnglish = null;
    });

    _playHebrewWord(word);
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
      hebrewList = currentChunk.map((x) => x.hebrew).toList();
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
      selectedEnglish = null;
      errorHebrew = null;
      errorEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;
    });
    _hebrewInputController.clear();
    _saveProgress();

    // Auto-start dictation if in audio mode
    if (gameMode == GameMode.audio) {
      _dictateNextWord();
    }
  }

  // Find a matching pair from currentChunk given hebrew and english strings
  WordPair? _findMatchingPair(String hebrew, String english) {
    for (final pair in currentChunk) {
      if (pair.hebrew == hebrew && pair.english == english) {
        return pair;
      }
    }
    return null;
  }

  // Check if an English word is a distractor (not in currentChunk)
  bool _isDistractor(String english) {
    return !currentChunk.any((pair) => pair.english == english);
  }

  void _onHebrewTap(String hebrew) async {
    if (isProcessing || gameMode != GameMode.normal) return;

    // If English is already selected, try to match
    if (selectedEnglish != null) {
      final matchedPair = _findMatchingPair(hebrew, selectedEnglish!);
      if (matchedPair != null) {
        await _handleCorrectMatch(matchedPair);
      } else {
        // Wrong match - show error on Hebrew
        setState(() {
          errorHebrew = hebrew;
          isProcessing = true;
        });
        await _animationController?.forward(from: 0.0);
        setState(() {
          errorHebrew = null;
          isProcessing = false;
        });
      }
    } else {
      // No English selected - select this Hebrew
      setState(() {
        selectedHebrew = hebrew;
        selectedEnglish = null;
        errorHebrew = null;
        errorEnglish = null;
      });
    }
  }

  void _onEnglishTap(String english) async {
    if (isProcessing) return;

    // In typing mode, just select the English word (unless it's a distractor)
    if (gameMode == GameMode.typing) {
      if (_isDistractor(english)) return;
      setState(() {
        selectedEnglish = english;
        selectedHebrew = null;
      });
      _hebrewInputController.clear();
      Future.delayed(const Duration(milliseconds: 100), () {
        _hebrewInputFocusNode.requestFocus();
      });
      return;
    }

    // If Hebrew is already selected, try to match
    if (selectedHebrew != null) {
      final matchedPair = _findMatchingPair(selectedHebrew!, english);
      if (matchedPair != null) {
        await _handleCorrectMatch(matchedPair);
      } else {
        // Wrong match - show error on English
        setState(() {
          errorEnglish = english;
          isProcessing = true;
        });
        await _animationController?.forward(from: 0.0);
        setState(() {
          errorEnglish = null;
          isProcessing = false;
        });
      }
    } else {
      // No Hebrew selected - select this English (unless it's a distractor)
      if (_isDistractor(english)) {
        // Don't select distractors
        return;
      }
      setState(() {
        selectedEnglish = english;
        selectedHebrew = null;
        errorHebrew = null;
        errorEnglish = null;
      });
    }
  }

  Future<void> _handleCorrectMatch(WordPair matchedPair) async {
    setState(() {
      isProcessing = true;
      flashingHebrew = matchedPair.hebrew;
      flashingEnglish = matchedPair.english;
    });
    await Future.delayed(const Duration(milliseconds: 600));

    final hIdx = hebrewList.indexOf(matchedPair.hebrew);
    final eIdx = englishList.indexOf(matchedPair.english);

    matchedPairs.add(matchedPair);
    _matchedListKey.currentState?.insertItem(matchedPairs.length - 1);

    hebrewList.removeAt(hIdx);
    _hebrewListKey.currentState?.removeItem(hIdx, (c, a) => _buildHebrewItem(matchedPair.hebrew, a, true));

    englishList.removeAt(eIdx);
    _englishListKey.currentState?.removeItem(eIdx, (c, a) => _buildEnglishItem(matchedPair.english, a, true));

    if (hebrewList.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 300));
      // Remove remaining distractor(s)
      while (englishList.isNotEmpty) {
        final last = englishList.removeAt(0);
        _englishListKey.currentState?.removeItem(0, (c, a) => _buildEnglishItem(last, a, true));
        await Future.delayed(const Duration(milliseconds: 350));
      }
      _resetAnimatedListKeys();
    }

    setState(() {
      selectedHebrew = null;
      selectedEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;
    });

    // In audio mode, dictate the next word after a delay
    if (gameMode == GameMode.audio && hebrewList.isNotEmpty) {
      await Future.delayed(const Duration(seconds: 1));
      _dictateNextWord();
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

  Widget _buildHebrewItem(String word, Animation<double> animation, [bool isRemoving = false]) {
    final isSelected = !isRemoving && selectedHebrew == word;
    final isFlashing = !isRemoving && flashingHebrew == word;
    final isError = !isRemoving && errorHebrew == word;

    return AnimatedBuilder(
      animation: _animationController!,
      builder: (context, child) {
        double offset = isError ? sin(_animationController!.value * pi * 4) * 5 : (isFlashing ? sin(_animationController!.value * pi * 8) * 3 : 0.0);
        return Transform.translate(
          offset: Offset(offset, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: InkWell(
              onTap: isRemoving ? null : () => _onHebrewTap(word),
              child: Container(
                padding: const EdgeInsets.all(12.0),
                decoration: isFlashing || isSelected
                    ? BoxDecoration(color: Colors.green.shade200, borderRadius: BorderRadius.circular(8))
                    : (isError ? BoxDecoration(color: Colors.red.shade200, borderRadius: BorderRadius.circular(8)) : null),
                child: Text(word,
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
    final isSelected = !isRemoving && selectedEnglish == word;
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
                decoration: isFlashing || isSelected
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
      selectedEnglish = null;
      errorHebrew = null;
      errorEnglish = null;
      flashingHebrew = null;
      flashingEnglish = null;
      isProcessing = false;
    });
  }

  Widget _buildHebrewInputField() {
    return AnimatedBuilder(
      animation: _animationController!,
      builder: (context, child) {
        final isError = isProcessing && errorHebrew == '_typing_error';
        final isSuccess = flashingHebrew == '_typing_success';
        final offset = isError ? sin(_animationController!.value * pi * 4) * 5 : 0.0;

        return Transform.translate(
          offset: Offset(offset, 0),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16.0),
            decoration: (isSuccess || isError)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: isSuccess ? Colors.green.withAlpha(160) : Colors.red.withAlpha(150),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            child: TextField(
              controller: _hebrewInputController,
              focusNode: _hebrewInputFocusNode,
              enabled: selectedEnglish != null,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 24, height: 1.2),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: isError ? Colors.red.shade200 : Colors.blue, width: 2),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: isSuccess ? Colors.green : (isError ? Colors.red.shade200 : Colors.grey.shade400), width: (isSuccess || isError) ? 3 : 1),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: (_) => _submitTypedHebrew(),
            ),
          ),
        );
      },
    );
  }

  IconData _getModeIcon(GameMode mode) {
    switch (mode) {
      case GameMode.normal:
        return Icons.compare_arrows;
      case GameMode.audio:
        return Icons.volume_up;
      case GameMode.typing:
        return Icons.keyboard;
    }
  }

  Widget _buildModeSwitchRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, left: 16.0, right: 16.0, bottom: 4.0),
      child: SizedBox(
        height: 48,
        child: Stack(
          children: [
            // Chunk number (centered)
            Center(
              child: AnimatedOpacity(
                opacity: _isModeSwitchExpanded ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Text(
                  '${currentChunkIndex + 1} / ${chunks.length}',
                  style: const TextStyle(fontSize: 18, color: Colors.black45),
                ),
              ),
            ),
            // Mode icon or expanded switch (right-aligned)
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  if (!_isModeSwitchExpanded) {
                    setState(() {
                      _isModeSwitchExpanded = true;
                    });
                  }
                },
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  alignment: Alignment.centerRight,
                  child: _isModeSwitchExpanded
                      ? SizedBox(
                          width: 220,
                          height: 48,
                          child: AnimatedToggleSwitch<GameMode>.size(
                            current: gameMode,
                            values: GameMode.values,
                            iconOpacity: 0.8,
                            indicatorSize: const Size.fromWidth(70),
                            height: 48,
                            iconBuilder: (mode) => Icon(
                              _getModeIcon(mode),
                              size: 24,
                              color: gameMode == mode ? Colors.white : Colors.grey.shade600,
                            ),
                            borderWidth: 2.0,
                            style: ToggleStyle(
                              backgroundColor: Colors.grey.shade200,
                              borderColor: Colors.grey.shade300,
                              indicatorColor: Colors.grey.shade500,
                            ),
                            onChanged: _onModeChanged,
                          ),
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.grey.shade300, width: 2),
                          ),
                          child: Icon(
                            _getModeIcon(gameMode),
                            size: 24,
                            color: Colors.grey.shade600,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
                  Flexible(
                    flex: 2,
                    child: Visibility(
                      visible: gameMode == GameMode.normal,
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
                      _buildModeSwitchRow(),
                      _buildMatchingArea(),
                      // Hebrew input field for typing mode
                      if (gameMode == GameMode.typing)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: _buildHebrewInputField(),
                        ),
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
                    ],
                  ),
      ),
    );
  }
}
