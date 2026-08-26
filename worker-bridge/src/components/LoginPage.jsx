import { BarChart3, LockKeyhole, Mail } from "lucide-react";
import { useState } from "react";
import { supabase } from "../lib/supabase.js";

export default function LoginPage({ setupMissing = false }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);

  const signIn = async (event) => {
    event.preventDefault();
    if (!supabase) return;
    setBusy(true); setMessage("");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) setMessage(error.message);
  };

  const magicLink = async () => {
    if (!email || !supabase) { setMessage("Enter your email first."); return; }
    setBusy(true); setMessage("");
    const { error } = await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: window.location.href.split("#")[0] } });
    setBusy(false);
    setMessage(error ? error.message : "Check your email for the secure sign-in link.");
  };

  return <main className="login-page">
    <section className="login-card">
      <div className="login-brand"><span><BarChart3 size={22} /></span><div><strong>Ricochet</strong><small>Reporting workspace</small></div></div>
      <div className="login-copy"><span className="eyebrow">Private team dashboard</span><h1>Welcome back</h1><p>One Supabase login opens reports, CSV matching, recordings, and authorized AI controls. No feature asks for a separate API key.</p></div>
      {setupMissing ? <div className="setup-warning"><LockKeyhole size={19} /><div><strong>This build needs its public Supabase configuration.</strong><span>Add the three values from <code>.env.example</code> to the GitHub Actions repository variables. Never add a service-role key.</span></div></div> : <form onSubmit={signIn}>
        <label>Email<input type="email" value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" required /></label>
        <label>Password<input type="password" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" required /></label>
        {message && <div className="login-message">{message}</div>}
        <button className="button primary login-submit" disabled={busy}><LockKeyhole size={16} />{busy ? "Signing in…" : "Sign in"}</button>
        <button className="button secondary login-submit" type="button" onClick={magicLink} disabled={busy}><Mail size={16} />Email me a sign-in link</button>
      </form>}
      <small className="security-note">Your login session is managed by Supabase Auth. Private service keys stay only in Cloudflare.</small>
    </section>
  </main>;
}
