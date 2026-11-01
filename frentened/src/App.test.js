import { render, screen } from '@testing-library/react';
import App from './App';

test('shows the login form when logged out', () => {
  localStorage.clear();
  render(<App />);
  expect(screen.getByRole('heading', { name: /log in/i })).toBeInTheDocument();
});
