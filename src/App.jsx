import React, { useEffect, useRef, useState } from 'react'
import { createClient } from '@supabase/supabase-js'
import { Award, LockKeyhole, ShieldCheck, Users, CheckCircle2, ArrowLeft, Download, LogOut, CalendarDays, KeyRound, Vote, RefreshCw } from 'lucide-react'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY
const configured = Boolean(url && key && !url.includes('YOUR_PROJECT'))
// Separate anonymous and administrator clients so voter calls remain anonymous.
const voterClient = configured ? createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
}) : null
const adminClient = configured ? createClient(url, key, {
  auth: { persistSession: true, storageKey: 'abigail-awards-admin', detectSessionInUrl: true }
}) : null

const awardLabels = {
  overall_male: 'Overall Best Male Staff',
  overall_female: 'Overall Best Female Staff',
  technical: 'Best Technical Staff',
  nontechnical: 'Best Non-Technical Staff',
  projects: 'Best Projects Staff'
}

function initialSelection(categories) {
  return Object.fromEntries(categories.map(category => [category.key, { nominee_id: '', reason: '' }]))
}

function Message({ text, type = 'error' }) {
  if (!text) return null
  return <div className={'message ' + type} role="status">{text}</div>
}

function VotingPanel() {
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [ballot, setBallot] = useState(null)
  const [answers, setAnswers] = useState({})
  const [done, setDone] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [recordings, setRecordings] = useState({})
  const [recordingCategory, setRecordingCategory] = useState(null)
  const recorderRef = useRef(null)
  const chunksRef = useRef([])
  const timeoutRef = useRef(null)
  const streamRef = useRef(null)

  function cleanupRecording() {
    if (timeoutRef.current) clearTimeout(timeoutRef.current)
    streamRef.current?.getTracks().forEach(track => track.stop())
    timeoutRef.current = null
    streamRef.current = null
    recorderRef.current = null
    setRecordingCategory(null)
  }
  useEffect(() => () => {
    if (timeoutRef.current) clearTimeout(timeoutRef.current)
    streamRef.current?.getTracks().forEach(track => track.stop())
    if (recorderRef.current?.state === 'recording') recorderRef.current.stop()
  }, [])

  async function startRecording(category) {
    setError('')
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      setError('This browser does not support voice recording. Please use a recent Chrome or Safari browser, or type your reason.')
      return
    }
    const mime = ['audio/webm;codecs=opus','audio/mp4','audio/webm','audio/ogg'].find(m => MediaRecorder.isTypeSupported(m))
    if (!mime) { setError('Voice recording format is not supported on this device. Please type your reason.'); return }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({audio:true})
      streamRef.current = stream
      chunksRef.current = []
      const recorder = new MediaRecorder(stream,{mimeType:mime,audioBitsPerSecond:24000})
      recorderRef.current = recorder
      recorder.ondataavailable = event => { if (event.data.size) chunksRef.current.push(event.data) }
      recorder.onstop = () => {
        const blob = new Blob(chunksRef.current,{type:recorder.mimeType.split(';')[0]})
        cleanupRecording()
        if (blob.size > 2097152) { setError('Voice note is too large. Record a shorter message.'); return }
        if (blob.size < 64) { setError('Recording was too short. Please try again.'); return }
        setRecordings(prev => ({...prev,[category]:{blob,url:URL.createObjectURL(blob),mime:blob.type}}))
        change(category,'reason','')
      }
      recorder.onerror = () => {cleanupRecording();setError('Recording failed. Please try again.')}
      recorder.start()
      setRecordingCategory(category)
      timeoutRef.current = setTimeout(() => { if (recorder.state === 'recording') recorder.stop() },60000)
    } catch {cleanupRecording();setError('Microphone permission was denied or unavailable. You can type your reason instead.')}
  }
  function stopRecording() { if (recorderRef.current?.state === 'recording') recorderRef.current.stop() }
  function clearRecording(category) {
    setRecordings(prev => {
      const next = {...prev}
      if (next[category]?.url) URL.revokeObjectURL(next[category].url)
      delete next[category]
      return next
    })
  }
  function blobToBase64(blob) {
    return new Promise((resolve,reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result).split(',')[1])
      reader.onerror = reject
      reader.readAsDataURL(blob)
    })
  }

  async function enter(event) {
    event.preventDefault()
    setBusy(true); setError('')
    try {
      const { data, error: problem } = await voterClient.rpc('check_voter', {
        p_name: name.trim(), p_code: code.trim().toUpperCase()
      })
      if (problem) throw problem
      if (!data?.ok) throw new Error(data?.error || 'Unable to verify this code.')
      setBallot(data); setAnswers(initialSelection(data.categories))
    } catch (problem) { setError(problem.message) }
    finally { setBusy(false) }
  }

  function change(category, field, value) {
    setAnswers(previous => ({ ...previous, [category]: { ...previous[category], [field]: value } }))
  }

  async function submit(event) {
    event.preventDefault()
    const choices = ballot.categories.map(category => ({
      category: category.key,
      nominee_id: answers[category.key]?.nominee_id,
      reason: recordings[category.key] ? '' : (answers[category.key]?.reason || '').trim()
    }))
    if (choices.some(choice => !choice.nominee_id || (!recordings[choice.category] && (choice.reason.length < 20 || choice.reason.length > 500)))) {
      setError('Select a nominee and either type 20–500 characters or record a voice note for every award.')
      return
    }
    if (recordingCategory) {setError('Stop recording before submitting.');return}
    if (!window.confirm('Submit your final votes? Voice recordings may identify you to the administrator. You cannot edit after submission.')) return
    setBusy(true); setError('')
    try {
      for (const choice of choices) {
        if (recordings[choice.category]) {
          choice.audio_base64 = await blobToBase64(recordings[choice.category].blob)
          choice.audio_mime = recordings[choice.category].mime
        }
      }
      const { data, error: problem } = await voterClient.rpc('submit_awards_ballot', {
        p_name: name.trim(), p_code: code.trim().toUpperCase(), p_votes: choices
      })
      if (problem) throw problem
      if (!data?.ok) throw new Error(data?.error || 'Unable to submit your ballot.')
      Object.values(recordings).forEach(r => URL.revokeObjectURL(r.url))
      setRecordings({}); setDone(true); setBallot(null); setCode(''); setAnswers({})
    } catch (problem) { setError(problem.message) }
    finally { setBusy(false) }
  }

  if (done) return <section className="card centered success-panel">
    <CheckCircle2 size={52} className="success-icon" />
    <h2>Thank you for recognizing excellence!</h2>
    <p>Your votes and reasons were securely submitted. Your selections are confidential and cannot be changed.</p>
    <button className="button secondary" onClick={() => { setDone(false); setName(''); setCode(''); setError('') }}>Back to home</button>
  </section>

  if (!ballot) return <section className="card form-card">
    <span className="eyebrow"><LockKeyhole size={16} /> PRIVATE STAFF VOTING</span>
    <h2>Enter your voting code</h2>
    <p>Use your registered staff name and the short private code given to you by the organizer. Don't share your code with anyone.</p>
    <form onSubmit={enter}>
      <label htmlFor="staffName">Your registered name</label>
      <input id="staffName" placeholder="Your name as registered" autoComplete="name" required value={name} onChange={e => setName(e.target.value)} />
      <label htmlFor="voterCode">Private 6-character code</label>
      <input id="voterCode" placeholder="E.g. KM7P4X" autoComplete="off" maxLength={6} minLength={6} required value={code} onChange={e => setCode(e.target.value.toUpperCase().replace(/[^A-Z2-9]/g, ''))} className="code-input" />
      <Message text={error} />
      <button className="button primary full" type="submit" disabled={busy}>{busy ? 'Verifying…' : 'Continue to my ballot'}</button>
    </form>
    <p className="privacy"><ShieldCheck size={16} /> Only your eligible categories will appear. Your ballot is confidential.</p>
  </section>

  return <section className="card ballot-card">
    <div className="ballot-top">
      <button type="button" className="back-button" onClick={() => { setBallot(null); setCode(''); setError('') }}><ArrowLeft size={16}/> Leave ballot</button>
      <span className="tag">{ballot.department}</span>
    </div>
    <span className="eyebrow"><Vote size={16}/> YOUR CONFIDENTIAL BALLOT</span>
    <h2>Welcome, {ballot.name}</h2>
    <p>Recognize colleagues for their contribution, teamwork and professionalism. Select one eligible colleague in each category and explain why they deserve the award.</p>
    <Message text={error} />
    <form onSubmit={submit}>
      {ballot.categories.map((category, index) => <div className="award-section" key={category.key}>
        <div className="award-heading"><span className="award-number">{String(index+1).padStart(2, '0')}</span><h3>{category.title}</h3></div>
        <label htmlFor={'nominee-'+category.key}>Choose your nominee</label>
        <select id={'nominee-'+category.key} required value={answers[category.key]?.nominee_id || ''} onChange={e => change(category.key, 'nominee_id', e.target.value)}>
          <option value="">Select a staff member</option>
          {category.nominees.map(nominee => <option value={nominee.id} key={nominee.id}>{nominee.name}</option>)}
        </select>
        <label htmlFor={'reason-'+category.key}>Reason for your nomination — type or record</label>
        {!recordings[category.key] && <textarea id={'reason-'+category.key} minLength={20} maxLength={500} rows={3} required placeholder="Describe a specific contribution or quality (at least 20 characters)…" value={answers[category.key]?.reason || ''} required={!recordings[category.key]} onChange={e => change(category.key, 'reason', e.target.value)} />}
        {!recordings[category.key] && <span className="character-count">{(answers[category.key]?.reason || '').trim().length}/500 characters</span>}
        <div className="audio-reason">
          {recordings[category.key] ? <>
            <audio controls src={recordings[category.key].url} aria-label={'Voice reason for '+category.title}/>
            <button type="button" className="button secondary small" onClick={()=>clearRecording(category.key)}>Delete and re-record</button>
          </> : recordingCategory===category.key ? <>
            <span className="recording-indicator">● Recording (up to 60 seconds)…</span>
            <button type="button" className="button primary small" onClick={stopRecording}>Stop and save recording</button>
          </> : <button type="button" className="button secondary small" disabled={recordingCategory!==null} onClick={()=>startRecording(category)}>🎙 Record a voice reason instead</button>}
          <span className="audio-help">Voice notes may reveal your identity. Only the authorized administrator can listen after voting closes.</span>
        </div>
      </div>)}
      <div className="privacy"><ShieldCheck size={18}/> Once submitted, votes are final. Typed reasons are not linked to voter names; voices may still identify speakers.</div>
      <button type="submit" className="button primary full" disabled={busy}>{busy ? 'Submitting confidential votes…' : 'Submit my final ballot'}</button>
    </form>
  </section>
}

function downloadCodes(codes) {
  const escape = value => '"' + String(value).replace(/"/g, '""') + '"'
  const content = '\uFEFFStaff Name,Private Voting Code\n' + codes.map(c => [c.name,c.code].map(escape).join(',')).join('\n')
  const blob = new Blob([content], { type: 'text/csv;charset=utf-8' })
  const link = document.createElement('a')
  const temporaryUrl = URL.createObjectURL(blob)
  link.href = temporaryUrl; link.download = 'abigail-awards-private-voting-codes.csv'
  document.body.appendChild(link); link.click(); link.remove()
  setTimeout(() => URL.revokeObjectURL(temporaryUrl), 1000)
}

function AdminPanel() {
  const [session, setSession] = useState(null)
  const [checking, setChecking] = useState(true)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [authorized, setAuthorized] = useState(false)
  const [staff, setStaff] = useState([])
  const [overview, setOverview] = useState(null)
  const [opensAt, setOpensAt] = useState('')
  const [closesAt, setClosesAt] = useState('')
  const [codes, setCodes] = useState(null)
  const [results, setResults] = useState(null)
  const [audioUrls, setAudioUrls] = useState({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    let active = true
    adminClient.auth.getSession().then(({data}) => {
      if (active) { setSession(data?.session || null); setChecking(false) }
    })
    const { data: listener } = adminClient.auth.onAuthStateChange((_event, s) => {
      if (active) { setSession(s); setChecking(false) }
    })
    return () => { active=false; listener.subscription.unsubscribe() }
  }, [])

  useEffect(() => {
    if (!session) { setAuthorized(false); setStaff([]); setOverview(null); return }
    let active=true
    adminClient.rpc('is_awards_admin').then(({data,error:problem}) => {
      if (!active) return
      if (problem || !data) { setAuthorized(false); setError('This account is not authorized as the awards administrator.'); return }
      setAuthorized(true)
    })
    return () => {active=false}
  }, [session?.user?.id])

  useEffect(() => { if (authorized) refresh() }, [authorized])

  async function call(fn,args={}) {
    const {data,error:problem} = await adminClient.rpc(fn,args)
    if (problem) throw problem
    return data
  }

  async function refresh() {
    try {
      const [members,summary] = await Promise.all([call('admin_staff'),call('admin_overview')])
      setStaff(members || []); setOverview(summary)
      const local = iso => {
        const date = new Date(iso); const offset = date.getTimezoneOffset()*60000
        return new Date(date.getTime()-offset).toISOString().slice(0,16)
      }
      setOpensAt(local(summary.opens_at)); setClosesAt(local(summary.closes_at))
    } catch (problem) { setError(problem.message) }
  }

  async function signIn(event) {
    event.preventDefault(); setBusy(true); setError('')
    const {error:problem} = await adminClient.auth.signInWithPassword({email:email.trim(),password})
    if (problem) setError(problem.message)
    setPassword(''); setBusy(false)
  }

  async function signOut() {
    await adminClient.auth.signOut()
    Object.values(audioUrls).forEach(url => URL.revokeObjectURL(url))
    setAudioUrls({}); setCodes(null); setResults(null); setAuthorized(false); setNotice(''); setError('')
  }

  async function setWindow(event) {
    event.preventDefault()
    if (!window.confirm('Save the voting schedule? Times will follow your device time zone.')) return
    setBusy(true); setError(''); setNotice('')
    try {
      await call('admin_set_window', {p_opens_at:new Date(opensAt).toISOString(),p_closes_at:new Date(closesAt).toISOString()})
      await refresh(); setNotice('Voting dates saved.')
    } catch (problem) { setError(problem.message) }
    finally {setBusy(false)}
  }

  async function issueCodes() {
    if (!window.confirm('Generate codes for all staff who do not already have one? Codes are visible only now.')) return
    setBusy(true); setError(''); setNotice('')
    try {
      const generated = await call('admin_generate_codes')
      setCodes(generated || [])
      await refresh()
      setNotice(generated.length ? 'Save the codes immediately before leaving this page.' : 'All staff already have codes.')
    } catch (problem) {setError(problem.message)}
    finally {setBusy(false)}
  }

  async function reissue(person) {
    if (!window.confirm('Replace the private code for '+person.name+'? Their old code will stop working.')) return
    setBusy(true); setError(''); setNotice('')
    try {
      const generated = await call('admin_reissue_code',{p_staff_id:person.id})
      setCodes([...(codes || []).filter(x => x.name!==generated.name),generated])
      await refresh()
      setNotice('Replacement generated. Share it privately and save it now.')
    } catch (problem) {setError(problem.message)}
    finally {setBusy(false)}
  }

  async function loadAudio(ballotId) {
    setBusy(true); setError('')
    try {
      const data = await call('admin_get_voice_reason',{p_ballot_id:ballotId})
      const binary = atob(data.base64)
      const bytes = new Uint8Array(binary.length)
      for (let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i)
      const blob = new Blob([bytes],{type:data.mime})
      setAudioUrls(prev=>({...prev,[ballotId]:URL.createObjectURL(blob)}))
    } catch(problem) {setError(problem.message)}
    finally {setBusy(false)}
  }

  async function showResults() {
    setBusy(true); setError('')
    try { setResults(await call('admin_results')) }
    catch (problem) {setError(problem.message)}
    finally {setBusy(false)}
  }

  if (checking) return <section className="card">Checking administrator access…</section>
  if (!session) return <section className="card form-card">
    <span className="eyebrow"><ShieldCheck size={16}/> RESTRICTED AREA</span>
    <h2>Administrator sign in</h2>
    <p>Only the authorized awards administrator can manage voting and view results.</p>
    <form onSubmit={signIn}>
      <label htmlFor="adminEmail">Admin email</label>
      <input id="adminEmail" type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)}/>
      <label htmlFor="adminPassword">Password</label>
      <input id="adminPassword" type="password" autoComplete="current-password" required value={password} onChange={e => setPassword(e.target.value)}/>
      <Message text={error}/>
      <button type="submit" disabled={busy} className="button primary full">{busy ? 'Signing in…' : 'Sign in securely'}</button>
    </form>
  </section>
  if (!authorized) return <section className="card form-card"><h2>Administrator authorization required</h2><Message text={error || 'Your account is not approved as the awards administrator.'}/><button className="button secondary" onClick={signOut}>Sign out</button></section>

  const registration = (overview?.departments || []).reduce((a,d)=>a+d.registered,0)
  const completed = (overview?.departments || []).reduce((a,d)=>a+d.submitted,0)
  const issued = (overview?.departments || []).reduce((a,d)=>a+d.issued,0)
  const closed = overview && Date.now() >= new Date(overview.closes_at).getTime()

  return <section className="admin-panel">
    <div className="admin-heading">
      <div><span className="eyebrow"><ShieldCheck size={16}/> ADMINISTRATOR ONLY</span><h2>Awards control center</h2></div>
      <button className="button secondary small" onClick={signOut}><LogOut size={16}/> Sign out</button>
    </div>
    <Message text={error}/><Message text={notice} type="success"/>
    <div className="stats">
      <div className="stat"><strong>{registration}</strong><span>Registered staff</span></div>
      <div className="stat"><strong>{issued}</strong><span>Codes issued</span></div>
      <div className="stat"><strong>{completed}</strong><span>Ballots submitted</span></div>
    </div>
    <div className="admin-grid">
      <div className="card">
        <span className="eyebrow"><CalendarDays size={16}/> VOTING SCHEDULE</span>
        <h3>Automatic opening and closing</h3>
        <form onSubmit={setWindow}>
          <label htmlFor="opening">Voting opens (local time)</label>
          <input type="datetime-local" id="opening" required value={opensAt} onChange={e=>setOpensAt(e.target.value)}/>
          <label htmlFor="closing">Voting closes (local time)</label>
          <input type="datetime-local" id="closing" required value={closesAt} onChange={e=>setClosesAt(e.target.value)}/>
          <button type="submit" className="button primary" disabled={busy}>Save dates</button>
        </form>
      </div>
      <div className="card">
        <span className="eyebrow"><KeyRound size={16}/> CODE MANAGEMENT</span>
        <h3>Private voting codes</h3>
        <p>Generate one unique 6-character code for every staff member without a code. Save the file immediately: codes cannot be retrieved later.</p>
        <button className="button primary" disabled={busy || !registration} onClick={issueCodes}><KeyRound size={16}/> Generate missing codes</button>
        {codes && <div className="code-download">
          <p><strong>{codes.length} newly generated code{codes.length===1?'':'s'}.</strong> They disappear on refresh.</p>
          {codes.length > 0 && <><button className="button secondary" onClick={()=>downloadCodes(codes)}><Download size={16}/> Download private CSV</button>
          <div className="codes-list">{codes.map(x=><div key={x.name}><span>{x.name}</span><code>{x.code}</code></div>)}</div></>}
        </div>}
      </div>
    </div>
    <div className="card">
      <div className="section-title"><div><span className="eyebrow"><Users size={16}/> STAFF REGISTER</span><h3>Approved staff and code status</h3></div><button className="button secondary small" onClick={refresh}><RefreshCw size={15}/> Refresh</button></div>
      <p>Names and departments are imported privately through Supabase. This screen never reveals any person's submitted choices.</p>
      <div className="table-wrap"><table><thead><tr><th>Name</th><th>Department</th><th>Gender</th><th>Code</th><th></th></tr></thead><tbody>
      {staff.map(person=><tr key={person.id}><td>{person.name}</td><td>{person.department}</td><td>{person.gender}</td><td><span className={person.has_code?'status yes':'status'}>{person.has_code?'Issued':'Not issued'}</span></td><td><button className="text-action" disabled={busy} onClick={()=>reissue(person)}>Replace code</button></td></tr>)}
      {!staff.length && <tr><td colSpan="5">No staff imported yet.</td></tr>}
      </tbody></table></div>
    </div>
    <div className="card">
      <span className="eyebrow"><Award size={16}/> RESULTS</span>
      <h3>Participation and sealed results</h3>
      <div className="participation">{(overview?.departments || []).map(d=><div key={d.department}>
        <div className="participation-line"><strong>{d.department}</strong><span>{d.submitted} / {d.registered} submitted</span></div>
        <div className="progress"><span style={{width:(d.registered ? d.submitted/d.registered*100 : 0)+'%'}}/></div>
      </div>)}</div>
      <p>{closed ? 'Voting is closed. Authorized administrator may now view nominees, totals and anonymized reasons.' : 'Results stay sealed until the configured voting deadline.'}</p>
      <button className="button primary" onClick={showResults} disabled={busy || !closed}><Award size={16}/> View final results</button>
      {results && <div className="results">
        {Object.entries(awardLabels).map(([category,label])=>{
          const matches=results.filter(r=>r.category===category)
          return <div className="result-category" key={category}><h4>{label}</h4>
            {!matches.length ? <p>No votes recorded.</p> : matches.map((r,i)=><details key={r.nominee+'-'+i}><summary>{r.nominee} <strong>{r.votes} vote{Number(r.votes)===1?'':'s'}</strong></summary>
              <div className="reasons"><b>Nomination reasons (voices may identify speakers)</b>{r.reasons.map((reason,j)=><div key={reason.id || j} className="reason-item">
                {reason.is_audio ? (audioUrls[reason.id] ? <audio controls src={audioUrls[reason.id]}/> : <button className="button secondary small" disabled={busy} onClick={()=>loadAudio(reason.id)}>Listen to private voice reason</button>) : <p>“{reason.text}”</p>}
              </div>)}</div>
            </details>)}
          </div>
        })}
      </div>}
    </div>
  </section>
}

export default function App() {
  const [mode,setMode]=useState('vote')
  return <div className="page">
    <header className="site-header"><div className="brand-icon"><Award size={26}/></div><div><strong>ABIGAIL FOUNDATION</strong><small>STAFF RECOGNITION AWARDS • 2026</small></div></header>
    <main>
      <div className="hero">
        <div className="hero-flower" aria-hidden="true">✦</div>
        <span className="hero-kicker">CELEBRATING THE PEOPLE WHO MAKE A DIFFERENCE</span>
        <h1>Recognizing <em>excellence</em> in every department.</h1>
        <p>Every contribution matters. Celebrate a colleague who has made a positive impact at Abigail Foundation.</p>
      </div>
      <nav className="tabs" aria-label="Website sections">
        <button type="button" className={mode==='vote'?'active':''} onClick={()=>setMode('vote')}><Vote size={17}/> Staff voting</button>
        <button type="button" className={mode==='admin'?'active':''} onClick={()=>setMode('admin')}><LockKeyhole size={17}/> Administrator</button>
      </nav>
      {!configured ? <section className="card form-card"><h2>Website setup pending</h2><p>Configure VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in Vercel before voting can begin.</p></section> : mode==='vote' ? <VotingPanel/> : <AdminPanel/>}
    </main>
    <footer>Abigail Foundation · Staff Recognition Awards 2026<br/><span>Confidential voting · Fair recognition · Stronger together</span></footer>
  </div>
}