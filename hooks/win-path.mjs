// Git Bash 형식(/c/Users/...)으로 들어온 Windows 경로를 C:\Users\... 로 바꾼다. 해당하지 않으면 그대로 돌려준다.
// 훅은 Windows에서만 부른다. 다른 운영체제에서 점검할 수 있도록 따로 둔 순수 함수다.
export function posixDriveToWin(p) {
  const m = /^\/([a-zA-Z])(?:\/(.*))?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:\\${(m[2] || '').replace(/\//g, '\\')}` : p;
}
