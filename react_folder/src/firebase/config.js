import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider } from "firebase/auth";
import { getFirestore } from "firebase/firestore";

const firebaseConfig = {
  apiKey: "AIzaSyCnd_BWedtLdAZjUhkn09Rs1kjFByIvF0I",
  authDomain: "athletevision09.firebaseapp.com",
  projectId: "athletevision09",
  storageBucket: "athletevision09.firebasestorage.app",
  messagingSenderId: "748197789708",
  appId: "1:748197789708:web:78e1c1bb51d6f02471ee29"
};

const app = initializeApp(firebaseConfig);

// YE TEENO EXPORTS HONI CHAHIYE (JavaScript Code):
export const auth = getAuth(app);
export const db = getFirestore(app);
export const googleProvider = new GoogleAuthProvider();

export default app;