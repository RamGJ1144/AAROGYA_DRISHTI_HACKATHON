const API = "http://localhost:5000/api";

export async function apiRequest(url, method = "GET", data = null) {
  const token = localStorage.getItem("token");

  const options = {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
    },
  };

  if (data instanceof FormData) {
    options.body = data;
  } else if (data) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(data);
  }

  const response = await fetch(API + url, options);
  const result = await response.json();

  if (!response.ok) {
    throw new Error(result.message || "Something went wrong");
  }

  return result;
}