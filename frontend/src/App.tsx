import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import Login from './pages/Login';
import LabList from './pages/LabList';
import LabView from './pages/LabView';
import Instructor from './pages/Instructor';

function ProtectedRoute({ children, role }: { children: JSX.Element, role?: string }) {
  const token = localStorage.getItem('token');
  if (!token) return <Navigate to="/login" />;
  
  if (role === 'instructor') {
      try {
          const payload = JSON.parse(atob(token.split('.')[1]));
          if (payload.role !== 'instructor') return <Navigate to="/labs" />;
      } catch (e) {
          return <Navigate to="/login" />;
      }
  }

  return children;
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Navigate to="/labs" />} />
        <Route path="/login" element={<Login />} />
        <Route path="/labs" element={<ProtectedRoute><LabList /></ProtectedRoute>} />
        <Route path="/labs/:id" element={<ProtectedRoute><LabView /></ProtectedRoute>} />
        <Route path="/instructor" element={<ProtectedRoute role="instructor"><Instructor /></ProtectedRoute>} />
      </Routes>
    </BrowserRouter>
  );
}
