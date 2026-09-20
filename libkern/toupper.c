int
toupper(int c)
{

	if(c < 'a' || c > 'z')
		return c;
	return (c-'a'+'A');
}

int
tolower(int c)
{

	if(c < 'A' || c > 'Z')
		return c;
	return (c-'A'+'a');
}

