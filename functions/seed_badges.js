const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');

const BADGES = {
  'badzoff@gmail.com': 'Sponsor',
  'ashatilov@gmail.com': 'Helper',
  'alena.petukhova1@gmail.com': 'Sponsor',
  'romanhilp22@gmail.com': 'Sponsor',
};

initializeApp({ projectId: 'togetherly-d4856' });
const auth = getAuth();
const db = getFirestore();

async function main() {
  for (const [email, badge] of Object.entries(BADGES)) {
    try {
      const user = await auth.getUserByEmail(email);
      await db.collection('users').doc(user.uid).set({ badge }, { merge: true });
      console.log(`✓ ${email} (${user.uid}) → ${badge}`);
    } catch (e) {
      console.error(`✗ ${email}: ${e.message}`);
    }
  }
}

main().then(() => process.exit(0));
