// Built-in voice dictation for sketch entry.
// Mic toggle + Web Speech API + measurement-to-parser-grammar transform.
// Speaks "five foot seven right" → puts "5'7 right" into #cmd and submits on "enter".

(function () {
  'use strict';

  const ONES = {
    zero:0, one:1, two:2, three:3, four:4, five:5, six:6, seven:7, eight:8, nine:9,
    ten:10, eleven:11, twelve:12, thirteen:13, fourteen:14, fifteen:15,
    sixteen:16, seventeen:17, eighteen:18, nineteen:19
  };
  const TENS = { twenty:20, thirty:30, forty:40, fifty:50, sixty:60, seventy:70, eighty:80, ninety:90 };

  // Collapse spelled-out numbers 0–99 into digits in-place.
  // Handles "twenty seven" → "27" and "twenty-seven" → "27" without touching
  // unrelated words OR standalone hyphens (which the speech engine may emit for
  // spoken "minus" between two measurements — those are handled in step 0 of
  // transform(), and need to survive this function intact).
  function wordsToDigits(s) {
    // Compound tens+ones: "twenty seven" or "twenty-seven" → "27"
    s = s.replace(/\b(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)[-\s]+(one|two|three|four|five|six|seven|eight|nine)\b/gi,
      (_, t, o) => String(TENS[t.toLowerCase()] + ONES[o.toLowerCase()]));
    // Single tens or ones words
    s = s.replace(/\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b/gi,
      (w) => {
        const k = w.toLowerCase();
        return String(ONES[k] !== undefined ? ONES[k] : TENS[k]);
      });
    return s;
  }

  // Direction mishear map. Web Speech API often hears "rate" for "right" etc.
  // Replacements happen unconditionally (lowercase only) because these words are unusual
  // in real measurement dictation — false positives are unlikely in this context.
  const MISHEARS = {
    rate: 'right', rite: 'right', write: 'right', wright: 'right',
    lefty: 'left', laughed: 'left',
    dawn: 'down', doubt: 'down'
  };

  // ---- User-trained corrections (persisted) ----
  // Map of misheard phrase → intended phrase, learned via the Train button.
  // Applied at the very start of transform() so the rest of the pipeline
  // (numbers, measurements, directions) sees the corrected words.
  const CORRECTIONS_KEY = 'cvalr-dictation-corrections';
  let corrections = [];

  function loadCorrections() {
    try {
      const raw = localStorage.getItem(CORRECTIONS_KEY);
      corrections = raw ? JSON.parse(raw) : [];
      if (!Array.isArray(corrections)) corrections = [];
    } catch (e) { corrections = []; }
  }
  function saveCorrections() {
    try { localStorage.setItem(CORRECTIONS_KEY, JSON.stringify(corrections)); } catch (e) {}
  }
  function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  function applyCorrections(s) {
    for (const c of corrections) {
      if (!c || !c.from) continue;
      s = s.replace(new RegExp('\\b' + escapeRegex(c.from) + '\\b', 'gi'), c.to);
    }
    return s;
  }
  // Derive a {from,to} mapping from a misheard transcript + the intended phrase,
  // by stripping the common leading/trailing words and keeping only the part that
  // actually differs. "private right" vs "five foot right" → {from:"private", to:"five foot"}.
  function deriveCorrection(heard, meant) {
    const h = heard.toLowerCase().trim().split(/\s+/).filter(Boolean);
    const m = meant.toLowerCase().trim().split(/\s+/).filter(Boolean);
    let i = 0;
    while (i < h.length && i < m.length && h[i] === m[i]) i++;
    let j = 0;
    while (j < h.length - i && j < m.length - i && h[h.length - 1 - j] === m[m.length - 1 - j]) j++;
    return { from: h.slice(i, h.length - j).join(' '), to: m.slice(i, m.length - j).join(' ') };
  }

  // Pure: speech transcript → sketch-parser input string + submit flag.
  // Exposed for console testing: Dictation.transform("five foot seven right enter")
  function transform(text) {
    let s = String(text || '').toLowerCase().trim();
    if (!s) return { text: '', submit: false };

    // -1. Apply user-trained corrections first (misheard phrase → intended).
    s = applyCorrections(s);

    // 0. Web Speech often emits the literal '-' / '+' characters for the spoken
    //    words "minus" / "plus" between numbers ("20 ft 6 - 10 ft", "5 ft + 3 ft").
    //    Convert to the words so the arithmetic step (3b) sees them uniformly.
    s = s.replace(/([\d'"])\s*-\s*(?=\d)/g, '$1 minus ');
    s = s.replace(/([\d'"])\s*\+\s*(?=\d)/g, '$1 plus ');

    // 1. Spelled numbers → digits.
    s = wordsToDigits(s);

    // 2. Measurement collapse. Inches WORD is optional — speech often drops it
    //    ("5 foot 7" is more common than "5 foot 7 inches"). A second digit after
    //    foot/feet is treated as inches when present.
    //    "5 foot 7 inches" → "5'7"   "5 foot 7" → "5'7"   "5 feet" → "5'"   "7 inches" → "7\""
    s = s.replace(/(\d+)\s*(?:foot|feet|ft)(?:\s+(\d+))?(?:\s*(?:inches?|in|"))?/g,
      (_, ft, inches) => ft + "'" + (inches || ''));
    s = s.replace(/(\d+)\s*(?:inches?|in)\b/g, '$1"');

    // 3. Direction mishear normalization.
    for (const wrong in MISHEARS) {
      s = s.replace(new RegExp('\\b' + wrong + '\\b', 'g'), MISHEARS[wrong]);
    }

    // 3b. Arithmetic on measurements: "20'6 minus 10'" → "10'6", "10' plus 6\"" → "10'6".
    //     Runs after measurement collapse so operands are already in X'Y form.
    //     Uses core.js parseLength + formatLength (loaded globally before this script).
    if (typeof parseLength === 'function' && typeof formatLength === 'function') {
      const MEAS = '\\d+(?:\'(?:\\d+)?"?)?|\\d+"|\\d+(?:\\.\\d+)?';
      const arithRe = new RegExp('(' + MEAS + ')\\s+(minus|plus)\\s+(' + MEAS + ')', 'g');
      // Apply repeatedly so chained "a minus b plus c" collapses left-to-right.
      let prev;
      do {
        prev = s;
        s = s.replace(arithRe, (match, a, op, b) => {
          const av = parseLength(a);
          const bv = parseLength(b);
          if (isNaN(av) || isNaN(bv)) return match;
          const result = op === 'minus' ? av - bv : av + bv;
          if (result < 0) return match;   // negative result is nonsense for a length; leave the raw expr so user sees the problem
          return formatLength(result);
        });
      } while (s !== prev);
    }

    // 3c. Strip "is <measurement>" verbal confirmation that follows a measurement
    //     (e.g. "20'6 minus 10' is 10'6" → after arith, "10'6 is 10'6"). The user
    //     spoke the expected answer aloud as a sanity check; the computed answer
    //     is already in place from step 3b, so we drop the spoken one. Requiring
    //     a measurement before "is" avoids stripping unrelated phrases like
    //     "this is 10 right".
    s = s.replace(/(\d+'(?:\d+)?"?|\d+")\s+is\s+\d+(?:'(?:\d+)?"?)?/g, '$1');
    // Drop the verbal connector "then" used between the arithmetic answer and "enter".
    s = s.replace(/\s+\bthen\b/g, '');

    // 4. Diagonal connector: spoken "and" between two directional clauses → "&".
    //    "4'r and 4'd" → "4'r & 4'd"   (one diagonal segment per core.js:81)
    s = s.replace(/\b(right|left|up|down|r|l|u|d)\s+and\s+(?=\d|\.?\d)/g, '$1 & ');

    // 5. Trailing "enter" → submit signal.
    let submit = false;
    const enterRe = /[\s,]*\benter\b[\s.!?]*$/i;
    if (enterRe.test(s)) {
      submit = true;
      s = s.replace(enterRe, '');
    }

    // 6. Normalize commas (any "<word> comma <word>" already lowercased; punctuation handled by speech engine).
    s = s.replace(/\s*,\s*/g, ', ').replace(/\s{2,}/g, ' ').trim();
    s = s.replace(/,\s*$/, '');

    return { text: s, submit };
  }

  // ---- DOM wiring ----

  // A staged value that is JUST a direction (with no length) means "auto-extend to
  // the next aligned vertex". Includes common single-letter mishears: "R"→"are/our",
  // "U"→"you", "L"→"el". Only applied when it's the WHOLE staged value, so these
  // everyday words never affect normal measurement dictation.
  const BARE_DIR = {
    right: 'r', left: 'l', up: 'u', down: 'd',
    r: 'r', l: 'l', u: 'u', d: 'd',
    are: 'r', our: 'r', el: 'l', you: 'u'
  };

  let recognition = null;
  let listening = false;
  let wantListening = false;   // sticky: continuous mode auto-restarts on onend until user toggles off
  let suppressListeningStatus = false;   // on auto-restart, keep the prior "Heard:" line visible
  let lastHeardRaw = '';       // raw transcript of the most recent dictation (for Train)
  let restartTimes = [];       // timestamps of recent auto-restarts (throttle runaway loops)
  let mobilePending = null;    // {cands, idx} for mobile auto-extend (no live preview there)

  function $(id) { return document.getElementById(id); }

  function setButtonState() {
    const btn = $('btnMic');
    if (!btn) return;
    if (listening) {
      btn.textContent = 'Stop';
      btn.style.background = '#c44';
    } else {
      btn.textContent = 'Dictate';
      btn.style.background = '';   // revert to .input-row button default
    }
  }

  function setStatus(msg) {
    const el = $('micStatus');
    if (el) el.textContent = msg;
  }

  // Status readout for the mobile snap preview. `info` = { count, idx, segment }
  // as returned by the page adapter's previewCandidate().
  function mobileSnapStatus(info, submit) {
    const seg = info.segment;
    const len = (typeof formatLength === 'function') ? formatLength(seg.length) : seg.length.toFixed(1) + 'ft';
    const more = (info.idx + 1 < info.count) ? ' — "next"/"last" or "enter"' : ' — "enter" to accept';
    setStatus('Snap ' + (info.idx + 1) + '/' + info.count + ': ' + len + ' ' + seg.dir.toUpperCase() + (submit ? '' : more));
  }

  // On-screen diagnostic log (no DevTools needed). Shows recent recognition
  // lifecycle events so mic-drop issues can be diagnosed from a screenshot.
  const logLines = [];
  function logEvent(msg) {
    const t = new Date();
    const stamp = t.toLocaleTimeString() + '.' + String(t.getMilliseconds()).padStart(3, '0');
    logLines.unshift(stamp + '  ' + msg);
    if (logLines.length > 14) logLines.pop();
    const el = $('micLog');
    if (el) el.textContent = logLines.join('\n');
  }

  function handleFinalResult(transcript) {
    lastHeardRaw = transcript.trim();
    const { text, submit } = transform(transcript);
    setStatus('Heard: "' + transcript.trim() + '" → ' + (text || '(empty)') + (submit ? '  [enter]' : ''));

    // Mobile path: the touch UI has no #cmd input. It exposes window.SketchEntryAdapter.
    // For auto-extend we drive the page's native chainPreview (the orange dashed line
    // the L/U/D/R buttons use) via adapter.previewCandidate, so there's a visual cue —
    // and "next"/"last" swap which candidate the preview points at. "enter" commits.
    const adapter = window.SketchEntryAdapter;
    if (adapter) {
      // Parse THIS utterance's transformed text for a bare-direction command.
      let s = (text || '').toLowerCase().trim();
      const jumpLast = /\b(last|farthest|far|end)\b/.test(s);
      s = s.replace(/\b(last|farthest|far|end)\b/g, ' ');
      let nextCount = 0;
      const sBare = s.replace(/\bnext\b/g, () => { nextCount++; return ' '; }).replace(/\s+/g, ' ').trim();
      const bare = BARE_DIR[sBare];

      // A bare direction after a length (typed, or from a laser in CValRScan)
      // finishes that wall rather than discarding the length for an
      // auto-extend. After a laser reading it is added at once.
      const pendingLength = (adapter.getEntry() || '').trim();
      if (bare && pendingLength && !/[a-z]\s*$/i.test(pendingLength)) {
        adapter.setEntry(pendingLength + ' ' + bare);
        const laser = window.CValRLaser && window.CValRLaser.pending;
        if (laser) window.CValRLaser.pending = false;
        if (submit || laser) adapter.commit();
        mobilePending = null;
        return;
      }

      // Bare direction (optionally + next/last): preview the chosen aligned candidate.
      if (bare && adapter.previewCandidate) {
        const probe = adapter.candidates ? adapter.candidates(bare) : [];
        if (!probe.length) {
          setStatus('No vertex aligned ' + bare.toUpperCase() + ' of the pen — say a length, or another direction.');
          mobilePending = null;
          return;
        }
        const idx = jumpLast ? probe.length - 1 : nextCount % probe.length;
        const info = adapter.previewCandidate(bare, idx);   // draws the orange preview line
        mobilePending = { dir: bare, count: info.count, idx: info.idx };
        mobileSnapStatus(info, submit);
        if (submit) { adapter.commit(); mobilePending = null; }
        return;
      }

      // "next"/"last" on its own → re-point the existing preview to another candidate.
      if ((nextCount > 0 || jumpLast) && sBare === '' && mobilePending && adapter.previewCandidate) {
        const n = mobilePending.count;
        const idx = jumpLast ? n - 1 : (mobilePending.idx + nextCount) % n;
        const info = adapter.previewCandidate(mobilePending.dir, idx);
        if (info) { mobilePending.idx = info.idx; mobileSnapStatus(info, submit); }
        if (submit) { adapter.commit(); mobilePending = null; }
        return;
      }

      // "enter" on its own with an active preview → commit it.
      if (submit && sBare === '' && nextCount === 0 && !jumpLast && mobilePending) {
        adapter.commit();
        mobilePending = null;
        return;
      }

      // Measurement path: accumulate transformed text into the entry, commit on "enter".
      if (text) {
        const current = (adapter.getEntry() || '').trim();
        const combined = current ? (current + ' ' + text) : text;
        adapter.setEntry(transform(combined).text);
      }
      if (submit) adapter.commit();
      return;
    }

    const cmd = $('cmd');
    if (!cmd) return;
    // APPEND to #cmd rather than overwrite, then RE-NORMALIZE the combined value.
    // The re-normalize step is what handles split utterances like
    //   final 1: "10 foot 6 right"     → "10'6 right"
    //   final 2: "and 10 foot 6 up"    → "and 10'6 up"
    // The "and" → "&" diagonal rewrite needs a preceding direction in the SAME
    // transform pass, so we re-run transform on the combined value. transform()
    // is idempotent on already-normalized text. Submit comes from the original
    // transcript only (the latest utterance ended with "enter" or it didn't).
    if (text) {
      const current = cmd.value.trim();
      const combined = current ? (current + ' ' + text) : text;
      cmd.value = transform(combined).text;
    }
    // --- Voice auto-extend (snap-to-vertex) ---
    // A bare direction PREVIEWS the aligned candidate live on the canvas (like the
    // keyboard flow); "enter" commits it. Spoken "next" steps to a FARTHER aligned
    // candidate (drawn as one dimensioned segment), and can be said on its own to
    // extend an existing preview. So both of these work:
    //   "up" → "next" → "enter"   (separate utterances: preview, extend, commit)
    //   "up next enter"           (one utterance)
    const canAuto = typeof commitWalkPreview === 'function'
                 && typeof findAlignedCandidatesHere === 'function'
                 && typeof state === 'object';
    let staged = cmd.value.trim().toLowerCase();
    // "last" / "far" / "farthest" / "end" → jump straight to the farthest aligned
    // candidate in one word. More reliable than repeated "next" because Chrome's
    // recognizer often drops the 2nd of two short words said as separate utterances.
    const jumpLast = /\b(last|farthest|far|end)\b/.test(staged);
    staged = staged.replace(/\b(last|farthest|far|end)\b/g, ' ');
    let nextCount = 0;
    const stagedNoNext = staged.replace(/\bnext\b/g, () => { nextCount++; return ' '; })
                               .replace(/\s+/g, ' ').trim();
    const bare = BARE_DIR[stagedNoNext];

    if (canAuto && bare) {
      const cands = findAlignedCandidatesHere(state.segments, bare);
      if (!cands.length) {
        setStatus('No vertex aligned ' + bare.toUpperCase() + ' of the pen — say a length, or try another direction.');
        cmd.value = '';
        return;
      }
      const idx = jumpLast ? cands.length - 1 : nextCount % cands.length;
      state.preview = { dir: bare, candIdx: idx, candidates: cands, jump: false };
      if (typeof render === 'function') render();          // show the preview live
      if (submit) commitWalkPreview();                     // "enter" commits it
      // Always clear #cmd: the preview is now the active object. A following
      // "next" extends it; a following "enter" (empty input) commits it via addCmd.
      cmd.value = '';
      return;
    }

    if (canAuto && stagedNoNext === '' && (nextCount > 0 || jumpLast)) {
      // "next" / "last" on its own — extend an existing preview.
      if (state.preview && state.preview.candidates) {
        const n = state.preview.candidates.length;
        state.preview.candIdx = jumpLast ? n - 1 : (state.preview.candIdx + nextCount) % n;
        if (typeof render === 'function') render();
        if (submit) { commitWalkPreview(); }
      } else {
        setStatus('Say a direction first (e.g. "up"), then "next" / "last" to extend.');
      }
      cmd.value = '';
      return;
    }

    if (submit && typeof addCmd === 'function') addCmd();
  }

  function startRecognition() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      setStatus('Speech recognition not supported in this browser.');
      return false;
    }
    recognition = new SR();
    recognition.continuous = true;
    recognition.interimResults = false;
    recognition.lang = 'en-US';
    recognition.onstart = () => {
      listening = true;
      setButtonState();
      logEvent('onstart');
      if (!suppressListeningStatus) setStatus('Listening…');
      suppressListeningStatus = false;
    };
    recognition.onerror = (e) => {
      logEvent('onerror: ' + e.error);
      if (e.error === 'no-speech') { setStatus('No speech yet — keep going.'); return; }
      if (e.error === 'aborted') return;                  // user-initiated stop
      if (e.error === 'not-allowed') {                    // hard permission denial — give up
        setStatus('Mic permission denied — enable it in the browser/site settings.');
        wantListening = false;
        return;
      }
      // network / service-not-allowed / other: usually transient (common on file://).
      // Keep the session alive and let onend's throttled auto-restart retry.
      if (e.error === 'service-not-allowed') setStatus('Speech service hiccup — retrying… (HTTPS/PWA is more reliable than file://)');
      else if (e.error === 'network') setStatus('Network hiccup — retrying…');
      else setStatus('Mic error: ' + e.error + ' — retrying…');
    };
    recognition.onresult = (event) => {
      restartTimes = [];   // a real result means the mic is working — clear the failure counter
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const r = event.results[i];
        if (r.isFinal) logEvent('result(final): "' + r[0].transcript.trim() + '"');
        if (r.isFinal) handleFinalResult(r[0].transcript);
      }
    };
    recognition.onend = () => {
      listening = false;
      setButtonState();
      logEvent('onend (wantListening=' + wantListening + ')');
      if (!wantListening) { setStatus('Stopped.'); return; }
      // Engine ended on its own (silence/timeout/transient error) — restart to keep
      // continuous behavior. Throttle so a persistently failing service can't spin-loop:
      // more than 6 restarts within 10s → give up with a helpful message.
      const now = Date.now();
      restartTimes = restartTimes.filter(t => now - t < 10000);
      restartTimes.push(now);
      if (restartTimes.length > 6) {
        wantListening = false;
        restartTimes = [];
        logEvent('GAVE UP (6 restarts in 10s)');
        setStatus('Mic kept dropping — click Dictate to retry. For reliable speech use the HTTPS/PWA version, not a local file.');
        return;
      }
      // Suppress the next onstart's "Listening…" so the previous "Heard:" line stays
      // visible across the pause — the user can verify the last capture at leisure.
      suppressListeningStatus = true;
      logEvent('auto-restart (#' + restartTimes.length + ')');
      try { recognition.start(); } catch (e) { logEvent('restart threw: ' + e.message); }
    };
    try {
      recognition.start();
      return true;
    } catch (e) {
      setStatus('Could not start: ' + e.message);
      return false;
    }
  }

  function stopRecognition() {
    if (recognition) {
      try { recognition.stop(); } catch (e) {}
    }
  }

  function toggleMic() {
    if (listening || wantListening) {
      wantListening = false;
      stopRecognition();
    } else {
      wantListening = true;
      const ok = startRecognition();
      if (!ok) wantListening = false;
    }
  }

  // Teach a correction for the last mishearing. Shows what was heard, asks what
  // you meant, then auto-derives the differing words and stores them as a rule.
  function trainCorrection() {
    if (!lastHeardRaw) {
      setStatus('Dictate something first, then Train to fix a mishearing.');
      return;
    }
    const meant = window.prompt(
      'Heard: "' + lastHeardRaw + '"\n\nType what you actually said (spoken form, e.g. "five foot right"):',
      '');
    if (meant == null) return;            // cancelled
    const trimmed = meant.trim();
    if (!trimmed) return;
    const corr = deriveCorrection(lastHeardRaw, trimmed);
    if (!corr.from || !corr.to) {
      setStatus('No difference detected between heard and meant — nothing to learn.');
      return;
    }
    const existing = corrections.findIndex(c => c.from === corr.from);
    if (existing >= 0) corrections[existing] = corr; else corrections.push(corr);
    saveCorrections();
    setStatus('Learned: "' + corr.from + '" → "' + corr.to + '". Re-dictate to use it.');
  }

  function init() {
    loadCorrections();
    const btn = $('btnMic');
    if (btn && btn.dataset.dictationBound !== '1') {   // attachSidebarHandlers may rebind on every render
      btn.dataset.dictationBound = '1';
      btn.addEventListener('click', toggleMic);
      setButtonState();
    }
    const train = $('btnTrain');
    if (train && train.dataset.dictationBound !== '1') {
      train.dataset.dictationBound = '1';
      train.addEventListener('click', trainCorrection);
    }
  }

  window.Dictation = { init, transform, trainCorrection };
})();
