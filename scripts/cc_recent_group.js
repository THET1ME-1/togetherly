const admin=require("firebase-admin");admin.initializeApp({credential:admin.credential.cert(require("./serviceAccountKey.json"))});
const db=admin.firestore();
(async()=>{const s=await db.collection("groups").select().get();
 let best=null,bt=0;for(const d of s.docs){const t=d.updateTime?d.updateTime.toMillis():0;if(t>bt){bt=t;best=d.id;}}
 console.log("RECENT="+best+" at "+new Date(bt).toISOString());process.exit(0);})();
