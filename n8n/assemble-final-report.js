const fs   = require('fs');
const path = require('path');

// This node runs strictly after Journey: Final Answer -- the true last
// journey write in Main's own straight-line success path -- and takes its
// directory straight from that node's own output. It reads whatever *.json
// files exist in that directory and renders them as a Markdown audit report
// (report.md), sectioned per pipeline step in canonical workflow order.
const input = $input.first().json;

let dir = null;
try {
  dir = path.dirname(input.file);
} catch (e) {}

// ---------------------------------------------------------------------------
// Canonical pipeline order (matches the order the workflow produces output,
// per sub-workflow execution sequence). Steps not listed here fall to the
// end, sorted by timestamp.
// ---------------------------------------------------------------------------
const STEP_ORDER = [
  'main/turn-start',
  'main/input-guardrails',
  'question/intent',
  'question/concept-enricher',
  'question/concept-expansion',
  'question/vector-search',
  'question/graphdb-mcp',
  'answer/concept-enricher',
  'main/final-answer',
  'main/short-memory',
];

const STEP_TITLES = {
  'main/turn-start':           'Turn Start — User Question',
  'main/input-guardrails':     'Input Guardrails',
  'question/intent':           'Intent Classification',
  'question/concept-enricher': 'Concept Enricher — Question Phase',
  'question/concept-expansion':'Concept Expansion (Knowledge Graph)',
  'question/vector-search':    'Vector Search (RAG Retrieval)',
  'question/graphdb-mcp':      'GraphDB MCP Agent',
  'answer/concept-enricher':   'Concept Enricher — Answer Phase',
  'main/final-answer':         'Final Answer',
  'main/short-memory':         'Short Memory Update',
};

const TYPE_ICON = {
  success: '✅', info: 'ℹ️', error: '❌', warning: '⚠️', unreadable: '⚠️',
};

// --- markdown helpers -------------------------------------------------------

// Fenced code block; switches to ~~~~ if the content itself contains ```.
function fence(text, lang) {
  const s = String(text == null ? '' : text);
  const marker = s.includes('```') ? '~~~~' : '```';
  return marker + (lang || '') + '\n' + s + '\n' + marker;
}

// Push headings inside embedded markdown (LLM answers etc.) down `levels`
// so they nest under this report's own ## step headings.
function demote(md, levels) {
  return String(md == null ? '' : md)
    .replace(/^(#{1,4})(\s)/gm, (m, h, sp) => '#'.repeat(Math.min(6, h.length + levels)) + sp);
}

function details(summary, body) {
  return '<details>\n<summary>' + summary + '</summary>\n\n' + body + '\n\n</details>';
}

function cell(v) {
  return String(v == null ? '' : v).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

function truncate(s, n) {
  s = String(s == null ? '' : s);
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function kvTable(pairs) {
  const rows = pairs.filter(p => p[1] !== undefined && p[1] !== null && p[1] !== '');
  if (!rows.length) return '_(no data)_';
  return ['| Field | Value |', '|---|---|']
    .concat(rows.map(p => '| **' + cell(p[0]) + '** | ' + cell(p[1]) + ' |'))
    .join('\n');
}

function fmtTime(ts) {
  return ts ? String(ts).replace('T', ' ').replace('Z', ' UTC') : 'unknown';
}

function elapsed(ts, t0) {
  if (!ts || !t0) return '';
  const d = new Date(ts) - new Date(t0);
  if (isNaN(d)) return '';
  return d >= 1000 ? '+' + (d / 1000).toFixed(1) + 's' : '+' + d + 'ms';
}

function rawJsonDetails(v) {
  let body;
  try { body = fence(JSON.stringify(v, null, 2), 'json'); }
  catch (e) { body = '_could not serialize: ' + e.message + '_'; }
  return details('Raw JSON', body);
}

// --- per-step renderers ------------------------------------------------------
// Each renderer takes the step's `value` object and returns an array of
// markdown blocks. Unknown steps fall back to a collapsed raw-JSON dump.

function renderConceptEnricher(v) {
  const ce = (v && v.conceptEnrichment) || {};
  const out = [];

  const stats = ce.stats || {};
  out.push(kvTable([
    ['Concepts extracted', stats.totalConcepts],
    ['Enriched concepts used', stats.enrichedConceptsUsed],
    ['Retrieval queries generated', stats.retrievalQueriesGenerated],
    ['Keywords extracted', stats.keywordsExtracted],
  ]));

  const concepts = Array.isArray(ce.messageConcepts) ? ce.messageConcepts : [];
  if (concepts.length) {
    out.push('**Extracted concepts (by match score):**');
    out.push([
      '| # | Concept | Score | Category | Definition |',
      '|---|---|---|---|---|',
    ].concat(concepts.map((c, i) => {
      const cat = (Array.isArray(c.categories) ? c.categories : [])
        .map(x => x && x.label).filter(Boolean).join(', ');
      const def = (((c.details || {}).definitions) || [])[0] || '';
      return '| ' + (i + 1) + ' | ' + cell(c.label) + ' | ' + cell(c.score) +
             ' | ' + cell(cat) + ' | ' + cell(truncate(def, 140)) + ' |';
    })).join('\n'));
  }

  if (ce.retrievalQueriesText) {
    const n = Array.isArray(ce.retrievalQueries) ? ce.retrievalQueries.length : '?';
    out.push(details('Retrieval queries (' + n + ')', fence(ce.retrievalQueriesText)));
  }
  if (ce.keywordsText) out.push(details('Keywords', ce.keywordsText));
  if (ce.llmContextText) {
    out.push(details('Knowledge-graph context sent to the LLM', demote(ce.llmContextText, 3)));
  }
  return out;
}

const RENDERERS = {
  'main/turn-start': v => [
    '> **Question:** ' + ((v && v.question) || '_none captured_'),
  ],

  'main/input-guardrails': v => [
    kvTable([
      ['Safe', v && v.is_safe ? '✅ yes' : '❌ NO'],
      ['Risk level', v && v.risk_level],
      ['Flags', v && Array.isArray(v.flags) && v.flags.length ? v.flags.join(', ') : 'none'],
      ['Reason', v && v.reason],
    ]),
  ],

  'question/intent': v => {
    const ic = (v && v.intentClassification) || {};
    return [kvTable([
      ['Language', ic.language],
      ['Impersonation role', ic.impersonationRole],
      ['User persona', ic.userPersona],
      ['Target action', ic.targetAction],
      ['Topics', ic.topics],
    ])];
  },

  'question/concept-enricher': renderConceptEnricher,
  'answer/concept-enricher':   renderConceptEnricher,

  'question/concept-expansion': v => {
    const cx = (v && v.conceptExpansion) || {};
    const out = [];
    const meta = cx.metadata || {};
    out.push(kvTable([
      ['Query', meta.query],
      ['Total concepts', meta.totalConcepts],
      ['Result', meta.expansionMessage],
    ]));

    const tiers = ((cx.retrieval || {}).tiers) || {};
    const tierRows = [];
    const TIER_LABELS = [
      ['tier1_seeds', 'Seed'], ['tier2_primary', 'Primary'],
      ['tier3_secondary', 'Secondary'], ['tier4_related', 'Related'],
    ];
    for (const [key, label] of TIER_LABELS) {
      for (const c of (Array.isArray(tiers[key]) ? tiers[key] : [])) {
        tierRows.push('| ' + label + ' | ' + cell(c.label) + ' | ' + cell(c.weight) + ' |');
      }
    }
    if (tierRows.length) {
      out.push(['**Expansion tiers:**', '', '| Tier | Concept | Weight |', '|---|---|---|']
        .concat(tierRows).join('\n'));
    }

    const ctx = (cx.llm || {}).contextString;
    if (ctx) out.push(details('Expansion context sent to the LLM', fence(ctx)));
    return out;
  },

  'question/vector-search': v => {
    const hits = (((v && v.vectorSearch) || {}).vector_hits) || [];
    if (!hits.length) return ['_No vector hits returned._'];
    const out = [];
    out.push('**' + hits.length + ' chunks retrieved:**');
    out.push([
      '| # | Score | Document | Chunk |',
      '|---|---|---|---|',
    ].concat(hits.map((h, i) => {
      const md = h.metadata || {};
      const doc = path.basename(String(md.doc_uri || h.source || ''));
      const score = typeof h.score === 'number' ? h.score.toFixed(3) : h.score;
      return '| ' + (i + 1) + ' | ' + cell(score) + ' | ' + cell(doc) +
             ' | ' + cell(md.seq != null ? md.seq : '') + ' |';
    })).join('\n'));
    out.push(details('Retrieved chunk contents', hits.map((h, i) => {
      const md = h.metadata || {};
      const doc = path.basename(String(md.doc_uri || h.source || ''));
      const score = typeof h.score === 'number' ? h.score.toFixed(3) : h.score;
      return '**Hit ' + (i + 1) + ' — ' + doc + ' (chunk ' +
             (md.seq != null ? md.seq : '?') + ', score ' + score + ')**\n\n' +
             fence(h.payload || md.content || '');
    }).join('\n\n')));
    return out;
  },

  'question/graphdb-mcp': v => {
    const g = (v && v.graphdbMcp) || {};
    // upstream key is (currently) misspelled "grpahdbMCPresponse" -- accept both
    const resp = g.grpahdbMCPresponse || g.graphdbMCPresponse || g.response;
    return resp ? [demote(resp, 2)] : [rawJsonDetails(v)];
  },

  'main/final-answer': v => {
    const out = [];
    if (v && v.prompt) out.push('> **Prompt:** ' + v.prompt);
    out.push('**Response delivered to the user:**');
    out.push(demote((v && v.response) || '_none captured_', 2));
    return out;
  },

  'main/short-memory': v => [fence((v && v.response) || '')],
};

// --- main --------------------------------------------------------------------

let written = false;
let error = null;
let reportPath = null;
let stepsFound = 0;

try {
  if (!dir) throw new Error('no directory available from Journey: Final Answer output');

  const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
  const records = [];
  for (const f of files) {
    try {
      const raw = fs.readFileSync(path.join(dir, f), 'utf-8');
      const parsed = JSON.parse(raw);
      records.push({
        file: f,
        ts: parsed.ts || null,
        phase: parsed.phase || '?',
        step: parsed.step || f,
        type: parsed.type || 'unknown',
        value: parsed.value,
        conversationId: parsed.conversationId,
        questionId: parsed.questionId,
      });
    } catch (e) {
      records.push({
        file: f, ts: null, phase: '?', step: f, type: 'unreadable',
        value: { parseError: e.message },
      });
    }
  }

  // Canonical workflow order first; unknown steps last, by timestamp.
  records.sort((a, b) => {
    const ka = STEP_ORDER.indexOf(a.phase + '/' + a.step);
    const kb = STEP_ORDER.indexOf(b.phase + '/' + b.step);
    const ia = ka === -1 ? Infinity : ka;
    const ib = kb === -1 ? Infinity : kb;
    if (ia !== ib) return ia - ib;
    if (a.ts && b.ts) return new Date(a.ts) - new Date(b.ts);
    return a.file.localeCompare(b.file);
  });

  stepsFound = records.length;

  const t0 = records.reduce((min, r) =>
    (r.ts && (!min || new Date(r.ts) < new Date(min))) ? r.ts : min, null);
  const first = records.find(r => r.conversationId) || {};
  const questionRec = records.find(r => r.phase === 'main' && r.step === 'turn-start');

  const md = [];

  // ---- header ----
  md.push('# GraphRAG Chatbot — Turn Audit Report');
  md.push('');
  md.push(kvTable([
    ['Generated', new Date().toISOString()],
    ['Conversation ID', first.conversationId],
    ['Question ID', first.questionId],
    ['Turn started', fmtTime(t0)],
    ['Steps captured', records.length],
    ['Source directory', dir],
  ]));
  md.push('');
  if (questionRec && questionRec.value && questionRec.value.question) {
    md.push('> ❓ **' + questionRec.value.question + '**');
    md.push('');
  }

  // ---- timeline ----
  md.push('## Pipeline Timeline');
  md.push('');
  md.push([
    '| # | Step | Phase | Timestamp | Elapsed | Status |',
    '|---|---|---|---|---|---|',
  ].concat(records.map((r, i) => {
    const key = r.phase + '/' + r.step;
    const title = STEP_TITLES[key] || r.step;
    const icon = TYPE_ICON[r.type] || r.type;
    return '| ' + (i + 1) + ' | [' + cell(title) + '](#step-' + (i + 1) + ') | ' +
           cell(r.phase) + ' | ' + cell(fmtTime(r.ts)) + ' | ' +
           cell(elapsed(r.ts, t0)) + ' | ' + icon + ' |';
  })).join('\n'));
  md.push('');
  md.push('---');
  md.push('');

  // ---- step sections ----
  records.forEach((r, i) => {
    const key = r.phase + '/' + r.step;
    const title = STEP_TITLES[key] || (r.phase + ' / ' + r.step);
    const icon = TYPE_ICON[r.type] || '';

    md.push('<a id="step-' + (i + 1) + '"></a>');
    md.push('## ' + (i + 1) + '. ' + title + ' ' + icon);
    md.push('');
    md.push('`' + key + '` · ' + r.type + ' · ' + fmtTime(r.ts) +
            (r.ts && t0 ? ' (' + elapsed(r.ts, t0) + ')' : '') +
            ' · source: `' + r.file + '`');
    md.push('');

    let blocks;
    try {
      const renderer = RENDERERS[key];
      blocks = renderer ? renderer(r.value) : [rawJsonDetails(r.value)];
    } catch (e) {
      blocks = ['⚠️ _renderer failed: ' + e.message + ' — raw dump below_', rawJsonDetails(r.value)];
    }
    for (const b of blocks) { md.push(b); md.push(''); }
    md.push('---');
    md.push('');
  });

  md.push('_End of report — ' + records.length + ' steps. Raw per-step JSON files are alongside this report in the same directory._');
  md.push('');

  reportPath = path.join(dir, 'report.md');
  fs.writeFileSync(reportPath, md.join('\n'), 'utf-8');
  written = true;
} catch (e) {
  error = e.message;
  try {
    if (dir) {
      fs.mkdirSync(dir, { recursive: true });
      reportPath = path.join(dir, 'report.md');
      fs.writeFileSync(reportPath, '# Report generation FAILED\n\n`' + e.message + '`\n', 'utf-8');
      written = true;
    }
  } catch (e2) {
    error = e.message + ' (fallback write also failed: ' + e2.message + ')';
  }
}

return [{ json: { written, error, file: reportPath, stepsFound } }];
