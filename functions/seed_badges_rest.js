const { execSync } = require('child_process');

const token = execSync('gcloud auth print-access-token', { encoding: 'utf8' }).trim();
const projectId = 'togetherly-d4856';

const BADGES = {
  'badzoff@gmail.com': 'Sponsor',
  'ashatilov@gmail.com': 'Helper',
  'alena.petukhova1@gmail.com': 'Sponsor',
  'romanhilp22@gmail.com': 'Sponsor',
};

async function lookupUser(email) {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v2/accounts:lookup?key=${projectId}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ email: [email] }),
    }
  );
  const data = await res.json();
  if (!res.ok) throw new Error(data.error?.message || res.statusText);
  return data.users?.[0]?.localId;
}

async function setBadge(uid, badge) {
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/users/${uid}?updateMask.fieldPaths=badge`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ fields: { badge: { stringValue: badge } } }),
  });
  if (!res.ok) {
    const data = await res.json();
    throw new Error(data.error?.message || res.statusText);
  }
}

async function main() {
  for (const [email, badge] of Object.entries(BADGES)) {
    try {
      const uid = await lookupUser(email);
      if (!uid) { console.error(`✗ ${email}: not found`); continue; }
      await setBadge(uid, badge);
      console.log(`✓ ${email} (${uid}) → ${badge}`);
    } catch (e) {
      console.error(`✗ ${email}: ${e.message}`);
    }
  }
}

main().then(() => process.exit(0));
