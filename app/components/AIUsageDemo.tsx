'use client'

import { useState } from 'react'
import styles from './AIUsageDemo.module.css'

type Window = { title: string; remaining: number; reset: string; expected?: number }
type Provider = { name: string; source: string; windows: Window[]; notice?: string; unavailable?: boolean }
// Explicitly fictional marketing examples. No visitor account or process access.
const providers: Provider[] = [
  { name: 'Codex', source: 'OAuth', windows: [{ title: 'Weekly quota', remaining: 96, reset: 'Oct 10 at 6:01 AM', expected: 6 }] },
  { name: 'Claude', source: 'OAuth', windows: [{ title: '5-hour', remaining: 98, reset: 'Today', expected: 30 }, { title: 'Weekly quota', remaining: 82, reset: 'Oct 8', expected: 20 }, { title: 'Fable only', remaining: 100, reset: 'Oct 8', expected: 20 }] },
  { name: 'Cursor', source: 'Web', windows: [
    { title: 'Total · Monthly quota', remaining: 85, reset: 'Oct 15', expected: 60 },
    { title: 'Cursor · Monthly quota', remaining: 88, reset: 'Oct 15', expected: 60 },
    { title: 'Third Party · Monthly quota', remaining: 0, reset: 'Oct 15', expected: 60 },
    { title: 'Grok Bot', remaining: 99, reset: 'Oct 9' },
  ] },
  { name: 'OpenCode Go', source: 'Local', windows: [], notice: 'Local estimate, not a provider measurement. Remaining quota unavailable.' },
  { name: 'Antigravity', source: 'CLI', windows: [
    { title: 'Gemini Models · Weekly quota', remaining: 98, reset: 'Oct 6', expected: 50 },
    { title: 'Claude and GPT · 5-hour', remaining: 80, reset: 'Today', expected: 30 },
  ] },
  { name: 'z.ai', source: 'API', windows: [{ title: '5-hour', remaining: 99, reset: 'Today', expected: 80 }, { title: 'Weekly quota', remaining: 99, reset: 'Oct 10', expected: 10 }] },
  { name: 'MiniMax', source: 'API', windows: [{ title: 'General · 5-hour', remaining: 98, reset: 'Today', expected: 30 }, { title: 'General · Weekly quota', remaining: 94, reset: 'Oct 4', expected: 70 }, { title: 'Video · Daily quota', remaining: 100, reset: 'Today', expected: 40 }] },
  { name: 'Kimi Code', source: 'API', windows: [{ title: 'Weekly quota', remaining: 99, reset: 'Oct 6', expected: 50 }, { title: '5-hour', remaining: 100, reset: 'Today', expected: 40 }] },
  { name: 'StepFun', source: 'Web', windows: [{ title: 'Credit', remaining: 90, reset: 'Reset time unavailable' }] },
]

export default function AIUsageDemo() {
  const [selected, setSelected] = useState<Provider | null>(null)
  const [mode, setMode] = useState<'pace' | 'rings'>('pace')
  const [refreshing, setRefreshing] = useState(false)
  const refresh = () => {
    if (refreshing) return
    setRefreshing(true)
    setTimeout(() => setRefreshing(false), 650)
  }
  return <div className={styles.root}>
    {selected && <button className={styles.back} onClick={() => setSelected(null)}>‹ All providers</button>}
    <h2>{selected?.name ?? 'AI usage'}</h2>
    <small>Demo data only. No account access.</small>
    {!selected ? <>
      <p>Each provider uses its own quota periods.</p>
      <button className={styles.back} disabled={refreshing} onClick={refresh}>{refreshing ? 'Querying…' : '↻ Refresh all'}</button>
      {providers.map(provider => <button key={provider.name} className={styles.overview} onClick={() => setSelected(provider)}>
        <span>{provider.name}<span>›</span></span>
        {provider.notice ? <small>{provider.notice}</small> : provider.windows.map(window => <span key={window.title}>{window.title}<strong>{window.remaining}% remaining</strong></span>)}
        {!provider.unavailable && <small>Last successful reading: 14:00 · demo data</small>}
      </button>)}
    </> : <>
      {selected.notice ? <p>{selected.notice}</p> : <>
        <div className={styles.modes} role="tablist" aria-label="Display mode">
          <button role="tab" aria-selected={mode === 'pace'} onClick={() => setMode('pace')}>Pace</button>
          <button role="tab" aria-selected={mode === 'rings'} onClick={() => setMode('rings')}>{selected.windows.length > 1 ? 'Rings' : 'Ring'}</button>
        </div>
        <div className={mode === 'rings' ? styles.rings : undefined}>
          {selected.windows.map(window => <section key={window.title} className={mode === 'rings' ? styles.ringSection : undefined}>
            {mode === 'pace' ? <>
              <h3>{window.title}</h3><div className={styles.value}>{window.remaining}% <small>remaining</small></div>
              <p>Resets: {window.reset}</p>
              <div className={styles.meter} role="img" aria-label={`Used ${100 - window.remaining}%`}><span style={{ width: `${100 - window.remaining}%` }} />{window.expected !== undefined && <i style={{ left: `${window.expected}%` }} />}</div>
              <div className={styles.legend}><span>Used {100 - window.remaining}%</span>{window.expected !== undefined && <span>Even budget {window.expected}%</span>}</div>
              {window.expected !== undefined ? <p>{Math.abs(100 - window.remaining - window.expected)} points {100 - window.remaining > window.expected ? 'ahead of' : 'behind'} even pace</p> : <p>Not enough timing data to calculate pace.</p>}
            </> : <>
              <div className={styles.ring}><svg viewBox="0 0 100 100" role="img" aria-label={`${window.title} ${window.remaining}% remaining`}>
                <circle className={styles.track} cx="50" cy="50" r="44" />
                <circle cx="50" cy="50" r="44" strokeDasharray="276.46" strokeDashoffset={276.46 * (1 - window.remaining / 100)} />
              </svg><strong>{window.remaining}%</strong></div><p>{window.title} · remaining</p><p>Resets: {window.reset}</p>
            </>}
          </section>)}
        </div>
        <small>Only quota windows returned by the provider are shown.</small>
      </>}
      {!selected.unavailable && <div className={styles.source}>Source: {selected.source} · collected account<br />Last successful reading: 14:00 · demo data</div>}
    </>}
    <footer><small>Demo data only. No account access.</small><button disabled={refreshing} onClick={refresh}>{refreshing ? 'Querying…' : '↻ Refresh'}</button></footer>
  </div>
}
