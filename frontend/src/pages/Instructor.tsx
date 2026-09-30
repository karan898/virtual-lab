import { useState, useEffect } from 'react';
import axios from 'axios';

interface AdminLab {
  id: string;
  username: string;
  template: string;
  status: string;
  startTime: string;
  provisionTime: string;
}

export default function Instructor() {
  const [labs, setLabs] = useState<AdminLab[]>([]);
  const token = localStorage.getItem('token');
  const config = { headers: { Authorization: `Bearer ${token}` } };

  const fetchLabs = async () => {
    try {
      const res = await axios.get('/api/admin/labs', config);
      setLabs(res.data);
    } catch (e) {
      console.error(e);
    }
  };

  useEffect(() => {
    fetchLabs();
    const interval = setInterval(fetchLabs, 10000);
    return () => clearInterval(interval);
  }, []);

  const forceDestroy = async (id: string) => {
    try {
      await axios.delete(`/api/admin/labs/${id}`, config);
      fetchLabs();
    } catch (e) {
      alert('Failed to destroy lab');
    }
  };

  return (
    <div className="container">
      <h2>Active Labs (Admin)</h2>
      <table>
        <thead>
          <tr>
            <th>Student</th>
            <th>Template</th>
            <th>Status</th>
            <th>Start Time</th>
            <th>Provision Time</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {labs.map(lab => (
            <tr key={lab.id}>
              <td>{lab.username}</td>
              <td>{lab.template}</td>
              <td><span className={`badge badge-${lab.status}`}>{lab.status}</span></td>
              <td>{new Date(lab.startTime).toLocaleString()}</td>
              <td>{lab.provisionTime}</td>
              <td>
                <button className="btn btn-danger" onClick={() => forceDestroy(lab.id)}>Force Destroy</button>
              </td>
            </tr>
          ))}
          {labs.length === 0 && (
            <tr><td colSpan={6}>No active labs</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
